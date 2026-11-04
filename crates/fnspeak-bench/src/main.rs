//! fnspeak-bench: score dictation systems on the things FnSpeak claims
//! to do better — your own vocabulary, filler removal, and self-correction
//! repair — using clips you recorded yourself.
//!
//! Each manifest line is one clip. A clip has either `audio` (a WAV file,
//! run through the speech engines) or `transcript` (a raw transcript, for
//! testing cleanup on its own). `external` holds what other tools produced
//! for the same clip, e.g. `{"other": "..."}`, so they're scored alongside.

mod metrics;

use anyhow::{bail, Context as _, Result};
use clap::Parser;
use fnspeak_core::cleanup::{AnthropicCleaner, Cleaner, LocalCleaner, LocalConfig, OpenAiCompatCleaner};
use fnspeak_core::stt::{FixedTranscript, SttEngine, SttHints, SAMPLE_RATE};
use fnspeak_core::vocab::{projects::index_projects, Source, VocabIndex};
use fnspeak_core::{CleanupMode, DictationContext, Pipeline};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Parser)]
#[command(about = "Score dictation systems on your vocabulary, filler removal and repairs")]
struct Args {
    /// JSONL manifest of clips.
    #[arg(long, default_value = "bench/manifest.jsonl")]
    manifest: PathBuf,
    /// Plain-text file of vocabulary terms, one per line.
    #[arg(long)]
    vocab: Option<PathBuf>,
    /// Also index this projects folder for vocabulary.
    #[arg(long)]
    projects: Option<PathBuf>,
    /// Whisper ggml model (needs the `whisper` feature).
    #[arg(long)]
    whisper: Option<PathBuf>,
    /// Whisper beam size; 1 is greedy decoding. Defaults to the app's setting.
    #[arg(long)]
    beam: Option<i32>,
    /// Parakeet sherpa-onnx model folder (needs the `parakeet` feature).
    #[arg(long)]
    parakeet: Option<PathBuf>,
    /// llama-server binary and GGUF model for local cleanup.
    #[arg(long, requires = "local_model")]
    llama_server: Option<PathBuf>,
    #[arg(long)]
    local_model: Option<PathBuf>,
    /// Claude model for cleanup; reads ANTHROPIC_API_KEY.
    #[arg(long)]
    anthropic_model: Option<String>,
    /// Model on an OpenAI-compatible endpoint; reads OPENAI_COMPAT_API_KEY.
    #[arg(long, requires = "compat_url")]
    compat_model: Option<String>,
    #[arg(long)]
    compat_url: Option<String>,
    /// Write per-clip outputs here as JSONL.
    #[arg(long)]
    details: Option<PathBuf>,
}

#[derive(Deserialize)]
struct Clip {
    id: String,
    #[serde(default)]
    category: String,
    reference: String,
    audio: Option<PathBuf>,
    transcript: Option<String>,
    #[serde(default)]
    terms: Vec<String>,
    #[serde(default)]
    context: DictationContext,
    #[serde(default)]
    external: BTreeMap<String, String>,
}

#[derive(Default)]
struct Score {
    clips: usize,
    word_errors: usize,
    ref_words: usize,
    terms_right: usize,
    terms_total: usize,
    fillers: usize,
    repair_errors: usize,
    repair_words: usize,
    stt_ms: u64,
    cleanup_ms: u64,
    fallbacks: usize,
}

impl Score {
    fn add(&mut self, clip: &Clip, text: &str, stt_ms: u64, cleanup_ms: u64, fell_back: bool) {
        let (errors, words) = metrics::word_errors(&clip.reference, text);
        self.clips += 1;
        self.word_errors += errors;
        self.ref_words += words;
        self.terms_right += metrics::terms_correct(text, &clip.terms);
        self.terms_total += clip.terms.len();
        self.fillers += metrics::fillers_left(&clip.reference, text);
        if clip.category == "repair" {
            self.repair_errors += errors;
            self.repair_words += words;
        }
        self.stt_ms += stt_ms;
        self.cleanup_ms += cleanup_ms;
        self.fallbacks += usize::from(fell_back);
    }

    fn row(&self, name: &str, timed: bool) -> String {
        let pct = |n: usize, d: usize| if d == 0 { "—".to_string() } else { format!("{:.1}%", 100.0 * n as f64 / d as f64) };
        let avg = |ms: u64| if timed && self.clips > 0 { format!("{} ms", ms / self.clips as u64) } else { "—".into() };
        format!(
            "| {name} | {} | {} | {} | {} | {} | {} | {} | {} | {} |",
            self.clips,
            pct(self.word_errors, self.ref_words),
            pct(self.terms_right, self.terms_total),
            self.fillers,
            pct(self.repair_errors, self.repair_words),
            avg(self.stt_ms),
            avg(self.cleanup_ms),
            avg(self.stt_ms + self.cleanup_ms),
            self.fallbacks,
        )
    }
}

fn main() -> Result<()> {
    let args = Args::parse();
    let clips = load_manifest(&args.manifest)?;
    let base = args.manifest.parent().unwrap_or(Path::new("."));
    let vocab_terms = load_vocab(&args)?;
    eprintln!("{} clips, {} vocabulary terms", clips.len(), vocab_terms.len());

    let mut rows: Vec<String> = Vec::new();
    let mut details: Vec<serde_json::Value> = Vec::new();

    // Other tools' output, scored as-is.
    let external: Vec<String> = clips.iter().flat_map(|c| c.external.keys().cloned()).collect::<std::collections::BTreeSet<_>>().into_iter().collect();
    for name in &external {
        let mut score = Score::default();
        for clip in clips.iter() {
            if let Some(text) = clip.external.get(name) {
                score.add(clip, text, 0, 0, false);
            }
        }
        rows.push(score.row(name, false));
    }

    // Speech sources: real engines for audio clips, the given transcript otherwise.
    let mut sources: Vec<(String, Option<Box<dyn SttEngine>>)> = vec![("transcript".into(), None)];
    for engine in speech_engines(&args)? {
        sources.push((engine.name().to_string(), Some(engine)));
    }

    let cleaners = cleaner_specs(&args);
    for (source_name, mut engine) in sources {
        let usable: Vec<&Clip> = clips
            .iter()
            .filter(|c| if engine.is_some() { c.audio.is_some() } else { c.transcript.is_some() })
            .collect();
        if usable.is_empty() {
            continue;
        }

        // Transcribe once per engine; every cleanup mode reuses it. Like the
        // app, the engine gets the vocabulary up front (Whisper uses it as its
        // starting prompt).
        let hints = SttHints { vocabulary: vocab_terms.iter().take(40).cloned().collect() };
        let mut raws: Vec<(String, u64)> = Vec::new();
        for clip in &usable {
            match (&mut engine, &clip.audio, &clip.transcript) {
                (Some(stt), Some(audio), _) => {
                    let samples = load_wav(&base.join(audio))?;
                    let started = std::time::Instant::now();
                    let raw = stt.transcribe(&samples, &hints)?;
                    raws.push((raw, started.elapsed().as_millis() as u64));
                }
                (None, _, Some(t)) => raws.push((t.clone(), 0)),
                _ => unreachable!(),
            }
        }

        // Raw output, with no cleanup at all.
        let mut score = Score::default();
        for (clip, (raw, ms)) in usable.iter().zip(&raws) {
            score.add(clip, raw, *ms, 0, false);
        }
        rows.push(score.row(&format!("{source_name} (raw)"), engine.is_some()));

        for spec in &cleaners {
            let cleaner = match spec.build() {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("skipping {}: {e}", spec.label());
                    continue;
                }
            };
            let mut vocab = VocabIndex::in_memory()?;
            vocab.add_terms(Source::User, &vocab_terms)?;
            let mut pipeline = Pipeline::new(Box::new(FixedTranscript(String::new())), vocab, spec.mode());
            pipeline.set_cleaner(cleaner);

            let label = format!("{source_name} → {}", spec.label());
            let mut score = Score::default();
            for (clip, (raw, stt_ms)) in usable.iter().zip(&raws) {
                let r = pipeline.clean(raw, &clip.context)?;
                score.add(clip, &r.text, *stt_ms, r.timings.cleanup_ms, r.fallback_reason.is_some());
                details.push(serde_json::json!({
                    "system": label, "id": clip.id, "raw": raw, "output": r.text,
                    "reference": clip.reference, "fallback": r.fallback_reason,
                }));
            }
            rows.push(score.row(&label, true));
        }
    }

    println!("| System | Clips | WER | Terms right | Fillers left | Repair WER | STT | Cleanup | Total | Fallbacks |");
    println!("|---|---|---|---|---|---|---|---|---|---|");
    for row in rows {
        println!("{row}");
    }
    if let Some(path) = &args.details {
        let lines: Vec<String> = details.iter().map(|d| d.to_string()).collect();
        fs::write(path, lines.join("\n") + "\n")?;
        eprintln!("per-clip output written to {}", path.display());
    }
    Ok(())
}

enum CleanerSpec {
    FilterOnly,
    Local { server: PathBuf, model: PathBuf },
    Anthropic { model: String },
    Compat { url: String, model: String },
}

impl CleanerSpec {
    fn label(&self) -> String {
        match self {
            CleanerSpec::FilterOnly => "filter only".into(),
            CleanerSpec::Local { model, .. } => format!("local {}", model.file_name().unwrap_or_default().to_string_lossy()),
            CleanerSpec::Anthropic { model } => model.clone(),
            CleanerSpec::Compat { model, .. } => model.clone(),
        }
    }

    fn mode(&self) -> CleanupMode {
        match self {
            CleanerSpec::FilterOnly => CleanupMode::FilterOnly,
            CleanerSpec::Local { .. } => CleanupMode::Local,
            _ => CleanupMode::Cloud,
        }
    }

    fn build(&self) -> Result<Option<Box<dyn Cleaner>>> {
        Ok(match self {
            CleanerSpec::FilterOnly => None,
            CleanerSpec::Local { server, model } => Some(Box::new(LocalCleaner::start(LocalConfig::new(server, model))?)),
            CleanerSpec::Anthropic { model } => {
                let key = std::env::var("ANTHROPIC_API_KEY").context("ANTHROPIC_API_KEY is not set")?;
                Some(Box::new(AnthropicCleaner::new(key, Some(model.clone()))?))
            }
            CleanerSpec::Compat { url, model } => {
                let key = std::env::var("OPENAI_COMPAT_API_KEY").ok();
                Some(Box::new(OpenAiCompatCleaner::new(url.clone(), key, model.clone())?))
            }
        })
    }
}

fn cleaner_specs(args: &Args) -> Vec<CleanerSpec> {
    let mut specs = vec![CleanerSpec::FilterOnly];
    if let (Some(server), Some(model)) = (&args.llama_server, &args.local_model) {
        specs.push(CleanerSpec::Local { server: server.clone(), model: model.clone() });
    }
    if let Some(model) = &args.anthropic_model {
        specs.push(CleanerSpec::Anthropic { model: model.clone() });
    }
    if let (Some(url), Some(model)) = (&args.compat_url, &args.compat_model) {
        specs.push(CleanerSpec::Compat { url: url.clone(), model: model.clone() });
    }
    specs
}

#[allow(unused_mut)]
fn speech_engines(args: &Args) -> Result<Vec<Box<dyn SttEngine>>> {
    let mut engines: Vec<Box<dyn SttEngine>> = Vec::new();
    if let Some(_path) = &args.whisper {
        #[cfg(feature = "whisper")]
        engines.push(Box::new(fnspeak_core::stt::WhisperEngine::load({
            let mut config = fnspeak_core::stt::WhisperConfig::new(_path);
            if let Some(beam) = args.beam {
                config.beam_size = beam;
            }
            config
        })?));
        #[cfg(not(feature = "whisper"))]
        bail!("--whisper needs a build with `--features whisper`");
    }
    if let Some(_dir) = &args.parakeet {
        #[cfg(feature = "parakeet")]
        engines.push(Box::new(fnspeak_core::stt::ParakeetEngine::load(fnspeak_core::stt::ParakeetConfig::new(_dir))?));
        #[cfg(not(feature = "parakeet"))]
        bail!("--parakeet needs a build with `--features parakeet`");
    }
    Ok(engines)
}

fn load_manifest(path: &Path) -> Result<Vec<Clip>> {
    let text = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    text.lines()
        .enumerate()
        .filter(|(_, l)| !l.trim().is_empty() && !l.trim_start().starts_with("//"))
        .map(|(i, l)| serde_json::from_str(l).with_context(|| format!("{}:{}", path.display(), i + 1)))
        .collect()
}

fn load_vocab(args: &Args) -> Result<Vec<String>> {
    let mut terms = Vec::new();
    if let Some(path) = &args.vocab {
        let text = fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        terms.extend(text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')).map(String::from));
    }
    if let Some(root) = &args.projects {
        terms.extend(index_projects(root)?);
    }
    Ok(terms)
}

/// Read a WAV file as 16 kHz mono f32, downmixing and resampling if needed.
fn load_wav(path: &Path) -> Result<Vec<f32>> {
    let mut reader = hound::WavReader::open(path).with_context(|| format!("opening {}", path.display()))?;
    let spec = reader.spec();
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader.samples::<f32>().collect::<Result<_, _>>()?,
        hound::SampleFormat::Int => {
            let scale = (1i64 << (spec.bits_per_sample - 1)) as f32;
            reader.samples::<i32>().map(|s| s.map(|v| v as f32 / scale)).collect::<Result<_, _>>()?
        }
    };
    let channels = spec.channels as usize;
    if channels == 0 {
        bail!("{} has no channels", path.display());
    }
    let mono: Vec<f32> = samples.chunks(channels).map(|f| f.iter().sum::<f32>() / channels as f32).collect();
    Ok(resample(&mono, spec.sample_rate, SAMPLE_RATE))
}

fn resample(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || input.is_empty() {
        return input.to_vec();
    }
    let ratio = from as f64 / to as f64;
    let len = (input.len() as f64 / ratio) as usize;
    (0..len)
        .map(|i| {
            let pos = i as f64 * ratio;
            let idx = pos as usize;
            let frac = (pos - idx as f64) as f32;
            let a = input[idx];
            let b = *input.get(idx + 1).unwrap_or(&a);
            a + (b - a) * frac
        })
        .collect()
}
