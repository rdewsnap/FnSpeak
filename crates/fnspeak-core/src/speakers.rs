//! Telling the voices on the far side of a call apart.
//!
//! Each utterance from the system-audio stream is turned into a voice
//! fingerprint (a speaker embedding) and compared with the voices heard so
//! far in this meeting. A close match joins that voice; anything else starts
//! a new one. Voices are numbered in the order they first speak: "Speaker 1",
//! "Speaker 2". Nothing here knows names, and nothing is kept past the
//! meeting: the fingerprints live in memory and go with the session.

use crate::stt::SAMPLE_RATE;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Cosine similarity at or above which an utterance joins a voice already
/// heard. Lower merges different people into one speaker; higher splits one
/// person into several.
///
/// UNTUNED: this can't be set properly without real meeting recordings.
/// 0.5 is sherpa-onnx's default for speaker verification, checked only
/// against a few clean clips with the CAM++ model the app downloads: three
/// real speakers scored 0.65 to 0.88 against themselves and at most 0.46
/// against each other (0.43 and 0.42 when cut to 2 s pieces), so 0.5 sat in
/// the gap. Two similar synthetic voices scored 0.7 and were merged. Call
/// audio (codecs, noise suppression, short turns) will score differently;
/// revisit with the `real_clips_group_by_speaker` test below.
pub const SPEAKER_MATCH_THRESHOLD: f32 = 0.5;

/// Utterances shorter than this aren't fingerprinted: a "yeah" or "mm-hm"
/// doesn't carry enough voice to compare, and would start a phantom speaker.
/// They go to whoever spoke last on the far side. The length includes the
/// padding the segmenter keeps around speech (about 400 ms).
pub const MIN_FINGERPRINT_MS: u32 = 1500;

/// Past this many voices, new ones join their nearest match. A call rarely
/// has more people talking, and a runaway count means the threshold is off.
pub const MAX_SPEAKERS: usize = 12;

/// "Speaker 3" for the third voice heard.
pub fn speaker_label(index: usize) -> String {
    format!("Speaker {}", index + 1)
}

/// Turns one utterance (16 kHz mono) into a voice fingerprint, or `None`
/// when it can't.
pub trait VoiceEmbedder: Send {
    fn embed(&mut self, audio: &[f32]) -> Option<Vec<f32>>;
}

/// One voice heard in a meeting.
#[derive(Clone, Debug, PartialEq)]
pub struct Voice {
    pub label: String,
    /// Unit-length average of the voice's fingerprints. What a later step
    /// would compare with remembered voices to put a name to the label.
    pub embedding: Vec<f32>,
    /// How many utterances were fingerprinted into it.
    pub utterances: usize,
}

/// Says who on the far side spoke an utterance.
pub trait SpeakerLabeller: Send {
    /// A label to store instead of "others", or `None` to leave it.
    /// `started_ms` is where the utterance began in the meeting.
    fn label(&mut self, audio: &[f32], started_ms: i64) -> Option<String>;

    /// The meeting is over: nothing more will be labelled.
    fn finish(&mut self) {}

    /// The voices heard so far, in the order they first spoke.
    fn voices(&self) -> Vec<Voice> {
        Vec::new()
    }
}

struct Cluster {
    /// Sum of unit-length fingerprints; its direction is the centroid.
    sum: Vec<f32>,
    count: usize,
}

/// Groups utterances by voice as they arrive.
pub struct VoiceLabeller {
    embedder: Box<dyn VoiceEmbedder>,
    threshold: f32,
    clusters: Vec<Cluster>,
    /// The far-side voice that spoke last.
    last: Option<usize>,
    diagnostics: Option<Diagnostics>,
}

impl VoiceLabeller {
    pub fn new(embedder: Box<dyn VoiceEmbedder>) -> Self {
        Self::with_threshold(embedder, SPEAKER_MATCH_THRESHOLD)
    }

    pub fn with_threshold(embedder: Box<dyn VoiceEmbedder>, threshold: f32) -> Self {
        VoiceLabeller { embedder, threshold, clusters: Vec::new(), last: None, diagnostics: None }
    }

    /// Also write how each utterance scored to `file`, for tuning
    /// [`SPEAKER_MATCH_THRESHOLD`]. See [`Diagnostics`].
    pub fn with_diagnostics(mut self, file: impl Into<PathBuf>) -> Self {
        self.diagnostics = Some(Diagnostics::start(file.into(), self.threshold));
        self
    }

    /// How close a fingerprint is to each voice heard so far.
    fn scores(&self, embedding: &[f32]) -> Vec<f32> {
        self.clusters.iter().map(|c| if c.sum.len() == embedding.len() { cosine(&c.sum, embedding) } else { -1.0 }).collect()
    }

    fn assign(&mut self, embedding: &[f32], scores: &[f32]) -> (usize, &'static str) {
        let best = scores.iter().copied().enumerate().max_by(|a, b| a.1.total_cmp(&b.1));
        match best {
            Some((i, score)) if score >= self.threshold => {
                let cluster = &mut self.clusters[i];
                cluster.sum.iter_mut().zip(embedding).for_each(|(s, e)| *s += e);
                cluster.count += 1;
                (i, "joined")
            }
            // Full: the nearest voice takes it, but isn't pulled towards it.
            Some((i, _)) if self.clusters.len() >= MAX_SPEAKERS => (i, "full"),
            _ => {
                self.clusters.push(Cluster { sum: embedding.to_vec(), count: 1 });
                (self.clusters.len() - 1, "new")
            }
        }
    }
}

impl SpeakerLabeller for VoiceLabeller {
    fn label(&mut self, audio: &[f32], started_ms: i64) -> Option<String> {
        let long_enough = audio.len() as u64 * 1000 >= MIN_FINGERPRINT_MS as u64 * SAMPLE_RATE as u64;
        let embedding = if long_enough { self.embedder.embed(audio).and_then(normalized) } else { None };
        // Too short or unreadable: whoever spoke last, if anyone has.
        let mut decision = if long_enough { "unreadable" } else { "short" };
        let mut scores = Vec::new();
        if let Some(embedding) = &embedding {
            scores = self.scores(embedding);
            let (voice, how) = self.assign(embedding, &scores);
            self.last = Some(voice);
            decision = how;
        }
        if let Some(diagnostics) = self.diagnostics.as_mut() {
            let duration_ms = audio.len() as u64 * 1000 / SAMPLE_RATE as u64;
            diagnostics.turn(started_ms, duration_ms, decision, self.last, &scores, embedding);
        }
        self.last.map(speaker_label)
    }

    fn finish(&mut self) {
        let voices = self.voices();
        if let Some(diagnostics) = self.diagnostics.as_mut() {
            diagnostics.finish(&voices);
        }
    }

    fn voices(&self) -> Vec<Voice> {
        self.clusters
            .iter()
            .enumerate()
            .map(|(i, c)| Voice { label: speaker_label(i), embedding: normalized(c.sum.clone()).unwrap_or_default(), utterances: c.count })
            .collect()
    }
}

/// A plain-text record of how one meeting's far-side utterances scored, for
/// choosing [`SPEAKER_MATCH_THRESHOLD`] from real calls. One line per
/// utterance as it happens, then at the end how the voices and the
/// utterances compare with each other.
///
/// It holds similarity scores, times and labels. Never audio, never words,
/// and never the fingerprints themselves, so a voice can't be rebuilt or
/// recognised from it. The words are in the transcript; `start_ms` lines the
/// two up.
///
/// TEMPORARY: written for every meeting while the threshold is being tuned.
/// Once it's settled, drop this or put it behind a setting.
struct Diagnostics {
    file: PathBuf,
    turns: usize,
    /// Fingerprints of this meeting's utterances by turn number, in memory
    /// only, for the comparison written at the end.
    fingerprints: Vec<(usize, Vec<f32>)>,
}

/// Files kept per folder; older meetings' are removed.
const DIAGNOSTICS_KEPT: usize = 10;
/// The utterance comparison grows with the square of this.
const DIAGNOSTICS_MAX_COMPARED: usize = 300;

impl Diagnostics {
    fn start(file: PathBuf, threshold: f32) -> Self {
        if let Some(dir) = file.parent() {
            let _ = std::fs::create_dir_all(dir);
            prune_diagnostics(dir, &file);
        }
        let header = format!(
            "# FnSpeak speaker diagnostics. Scores, times and labels only: no audio, no words, no voice fingerprints.\n\
             # threshold {threshold}  min_fingerprint_ms {MIN_FINGERPRINT_MS}  max_speakers {MAX_SPEAKERS}\n\
             # decision: new = started a voice, joined = matched one, full = nearest voice at the cap,\n\
             #           short / unreadable = not fingerprinted, went to whoever spoke last\n\
             # scores = similarity to Speaker 1, Speaker 2, ... as they stood before this turn\n\
             turn\tstart_ms\tduration_ms\tdecision\tlabel\tscores\n"
        );
        let _ = std::fs::write(&file, header);
        Diagnostics { file, turns: 0, fingerprints: Vec::new() }
    }

    fn append(&self, text: &str) {
        if let Ok(mut file) = std::fs::OpenOptions::new().append(true).open(&self.file) {
            let _ = file.write_all(text.as_bytes());
        }
    }

    fn turn(&mut self, started_ms: i64, duration_ms: u64, decision: &str, voice: Option<usize>, scores: &[f32], embedding: Option<Vec<f32>>) {
        let label = voice.map(speaker_label).unwrap_or_else(|| "others".into());
        self.append(&format!("{}\t{started_ms}\t{duration_ms}\t{decision}\t{label}\t{}\n", self.turns, row(scores)));
        if let Some(embedding) = embedding.filter(|_| self.fingerprints.len() < DIAGNOSTICS_MAX_COMPARED) {
            self.fingerprints.push((self.turns, embedding));
        }
        self.turns += 1;
    }

    fn finish(&mut self, voices: &[Voice]) {
        let mut out = String::from("\n# voices: label, utterances fingerprinted into it, then its similarity to each voice\n");
        for voice in voices {
            let scores: Vec<f32> = voices.iter().map(|other| cosine(&voice.embedding, &other.embedding)).collect();
            out.push_str(&format!("{}\t{}\t{}\n", voice.label, voice.utterances, row(&scores)));
        }
        out.push_str("\n# utterances: turn, then its similarity to each fingerprinted turn, in the order of the turn column\n");
        for (turn, embedding) in &self.fingerprints {
            let scores: Vec<f32> = self.fingerprints.iter().map(|(_, other)| cosine(embedding, other)).collect();
            out.push_str(&format!("{turn}\t{}\n", row(&scores)));
        }
        self.append(&out);
        self.fingerprints.clear();
    }
}

fn row(scores: &[f32]) -> String {
    scores.iter().map(|s| format!("{s:.2}")).collect::<Vec<_>>().join(" ")
}

/// Keep the newest few diagnostics files in `dir`, and always `keep`.
fn prune_diagnostics(dir: &Path, keep: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p != keep && p.file_name().is_some_and(|n| n.to_string_lossy().starts_with(DIAGNOSTICS_PREFIX)))
        .filter_map(|p| Some((std::fs::metadata(&p).ok()?.modified().ok()?, p)))
        .collect();
    files.sort();
    let extra = files.len().saturating_sub(DIAGNOSTICS_KEPT - 1);
    for (_, old) in files.into_iter().take(extra) {
        let _ = std::fs::remove_file(old);
    }
}

const DIAGNOSTICS_PREFIX: &str = "speakers-meeting-";

/// Where a meeting's speaker diagnostics go, inside `dir`.
pub fn diagnostics_file(dir: &Path, meeting_id: i64) -> PathBuf {
    dir.join(format!("{DIAGNOSTICS_PREFIX}{meeting_id}.txt"))
}

fn normalized(mut v: Vec<f32>) -> Option<Vec<f32>> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if v.is_empty() || !norm.is_finite() || norm <= f32::EPSILON {
        return None;
    }
    v.iter_mut().for_each(|x| *x /= norm);
    Some(v)
}

pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let norms = a.iter().map(|x| x * x).sum::<f32>().sqrt() * b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norms > f32::EPSILON {
        dot / norms
    } else {
        0.0
    }
}

/// Fingerprints with a sherpa-onnx speaker-embedding model. The model is
/// loaded on first use, on the meeting's worker thread, so starting a
/// meeting doesn't wait for it.
#[cfg(feature = "parakeet")]
pub struct SherpaEmbedder {
    model: std::path::PathBuf,
    extractor: Option<sherpa_rs::speaker_id::EmbeddingExtractor>,
    failed: bool,
}

#[cfg(feature = "parakeet")]
impl SherpaEmbedder {
    pub fn new(model: impl Into<std::path::PathBuf>) -> Self {
        SherpaEmbedder { model: model.into(), extractor: None, failed: false }
    }
}

#[cfg(feature = "parakeet")]
impl VoiceEmbedder for SherpaEmbedder {
    fn embed(&mut self, audio: &[f32]) -> Option<Vec<f32>> {
        use sherpa_rs::speaker_id::{EmbeddingExtractor, ExtractorConfig};
        if self.failed {
            return None;
        }
        if self.extractor.is_none() {
            let config = ExtractorConfig { model: self.model.to_string_lossy().into_owned(), ..Default::default() };
            match EmbeddingExtractor::new(config) {
                Ok(extractor) => self.extractor = Some(extractor),
                Err(e) => {
                    log::warn!("speaker model wouldn't load, far-side speakers stay unseparated: {e}");
                    self.failed = true;
                    return None;
                }
            }
        }
        self.extractor.as_mut()?.compute_speaker_embedding(audio.to_vec(), SAMPLE_RATE).ok()
    }
}

/// A truncated download isn't a model; sherpa-onnx aborts on one.
#[cfg(feature = "parakeet")]
const MIN_MODEL_BYTES: u64 = 1_000_000;

/// The labeller for a meeting, given where the speaker-embedding model
/// should be. `None` when this build has no model runtime or the file isn't
/// there, and then the far side stays "others". With `diagnostics`, the
/// meeting's scores are written to that file (see [`diagnostics_file`]).
pub fn voice_labeller(model: Option<&Path>, diagnostics: Option<PathBuf>) -> Option<Box<dyn SpeakerLabeller>> {
    #[cfg(feature = "parakeet")]
    {
        let model = model?;
        let size = std::fs::metadata(model).ok().filter(|m| m.is_file())?.len();
        if size < MIN_MODEL_BYTES {
            return None;
        }
        let labeller = VoiceLabeller::new(Box::new(SherpaEmbedder::new(model)));
        Some(Box::new(match diagnostics {
            Some(file) => labeller.with_diagnostics(file),
            None => labeller,
        }))
    }
    #[cfg(not(feature = "parakeet"))]
    {
        let _ = (model, diagnostics);
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reads the fingerprint straight out of the audio's first three samples.
    struct FirstSamples;
    impl VoiceEmbedder for FirstSamples {
        fn embed(&mut self, audio: &[f32]) -> Option<Vec<f32>> {
            (audio[0] >= 0.0).then(|| audio[..3].to_vec())
        }
    }

    fn utterance(voice: [f32; 3], ms: u32) -> Vec<f32> {
        let mut audio = vec![0.0; (ms * SAMPLE_RATE / 1000) as usize];
        audio[..3].copy_from_slice(&voice);
        audio
    }

    const ANA: [f32; 3] = [1.0, 0.1, 0.0];
    const ANA_AGAIN: [f32; 3] = [0.9, 0.0, 0.2];
    const BEN: [f32; 3] = [0.0, 1.0, 0.1];
    const CAT: [f32; 3] = [0.1, 0.0, 1.0];
    const UNREADABLE: [f32; 3] = [-1.0, 0.0, 0.0];

    fn labeller() -> VoiceLabeller {
        VoiceLabeller::new(Box::new(FirstSamples))
    }

    #[test]
    fn groups_similar_voices_and_numbers_them_in_order() {
        let mut l = labeller();
        let said = [ANA, BEN, ANA_AGAIN, CAT, BEN, ANA];
        let labels: Vec<String> = said.iter().map(|v| l.label(&utterance(*v, 3000), 0).unwrap()).collect();
        assert_eq!(labels, ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 3", "Speaker 2", "Speaker 1"]);

        let voices = l.voices();
        assert_eq!(voices.iter().map(|v| v.utterances).collect::<Vec<_>>(), [3, 2, 1]);
        assert_eq!(voices[1].label, "Speaker 2");
        // Centroids come back unit length, ready to compare.
        for v in &voices {
            assert!((cosine(&v.embedding, &v.embedding) - 1.0).abs() < 1e-5);
            assert!((v.embedding.iter().map(|x| x * x).sum::<f32>() - 1.0).abs() < 1e-5);
        }
        assert!(cosine(&voices[0].embedding, &ANA) > 0.95);
    }

    #[test]
    fn short_utterances_go_to_whoever_spoke_last() {
        let mut l = labeller();
        // Nobody has spoken yet: nothing to inherit, and no speaker is made up.
        assert_eq!(l.label(&utterance(BEN, 600), 0), None);
        assert_eq!(l.label(&utterance(ANA, 3000), 0).as_deref(), Some("Speaker 1"));
        // Ben's "yeah" is too short to tell from Ana, so it stays with her.
        assert_eq!(l.label(&utterance(BEN, 600), 0).as_deref(), Some("Speaker 1"));
        assert_eq!(l.voices().len(), 1);
        assert_eq!(l.voices()[0].utterances, 1);
        assert_eq!(l.label(&utterance(BEN, MIN_FINGERPRINT_MS), 0).as_deref(), Some("Speaker 2"));
        assert_eq!(l.label(&utterance(ANA, MIN_FINGERPRINT_MS - 1), 0).as_deref(), Some("Speaker 2"));
    }

    #[test]
    fn unreadable_audio_inherits_too() {
        let mut l = labeller();
        assert_eq!(l.label(&utterance(UNREADABLE, 3000), 0), None);
        assert_eq!(l.label(&utterance(ANA, 3000), 0).as_deref(), Some("Speaker 1"));
        assert_eq!(l.label(&utterance(UNREADABLE, 3000), 0).as_deref(), Some("Speaker 1"));
        // A silent fingerprint (all zeros) can't be compared either.
        assert_eq!(l.label(&utterance([0.0; 3], 3000), 0).as_deref(), Some("Speaker 1"));
        assert_eq!(l.voices().len(), 1);
    }

    #[test]
    fn threshold_decides_between_joining_and_splitting() {
        let near_ana = [1.0, 0.8, 0.0]; // cosine with ANA is about 0.84
        let mut strict = VoiceLabeller::with_threshold(Box::new(FirstSamples), 0.9);
        strict.label(&utterance(ANA, 3000), 0);
        assert_eq!(strict.label(&utterance(near_ana, 3000), 0).as_deref(), Some("Speaker 2"));
        let mut loose = VoiceLabeller::with_threshold(Box::new(FirstSamples), 0.8);
        loose.label(&utterance(ANA, 3000), 0);
        assert_eq!(loose.label(&utterance(near_ana, 3000), 0).as_deref(), Some("Speaker 1"));
    }

    #[test]
    fn stops_inventing_speakers_at_the_cap() {
        struct OneHot;
        impl VoiceEmbedder for OneHot {
            fn embed(&mut self, audio: &[f32]) -> Option<Vec<f32>> {
                let mut v = vec![0.0; MAX_SPEAKERS + 5];
                v[audio[0] as usize] = 1.0;
                Some(v)
            }
        }
        let mut l = VoiceLabeller::new(Box::new(OneHot));
        for i in 0..MAX_SPEAKERS + 5 {
            l.label(&utterance([i as f32, 0.0, 0.0], 3000), 0);
        }
        assert_eq!(l.voices().len(), MAX_SPEAKERS);
    }

    #[test]
    fn diagnostics_record_scores_and_nothing_else() {
        let dir = tempfile::tempdir().unwrap();
        let folder = dir.path().join("Diagnostics");
        std::fs::create_dir_all(&folder).unwrap();
        // Left over from earlier meetings: only the newest few survive.
        for id in 0..15 {
            std::fs::write(diagnostics_file(&folder, id), "old").unwrap();
        }
        std::fs::write(folder.join("unrelated.txt"), "keep me").unwrap();

        let file = diagnostics_file(&folder, 42);
        let mut l = labeller().with_diagnostics(&file);
        l.label(&utterance(BEN, 600), 100);
        l.label(&utterance(ANA, 3000), 1_800);
        l.label(&utterance(BEN, 2000), 6_000);
        l.label(&utterance(ANA_AGAIN, 2500), 9_500);
        // Written as it goes, so a crash mid-meeting still leaves the turns.
        let so_far = std::fs::read_to_string(&file).unwrap();
        assert!(so_far.contains("0\t100\t600\tshort\tothers\t\n"));
        assert!(so_far.contains("1\t1800\t3000\tnew\tSpeaker 1\t\n"));
        assert!(so_far.contains("2\t6000\t2000\tnew\tSpeaker 2\t0.10\n"));
        assert!(so_far.contains("3\t9500\t2500\tjoined\tSpeaker 1\t0.97 0.02\n"), "{so_far}");
        assert!(!so_far.contains("# voices"));

        l.finish();
        let done = std::fs::read_to_string(&file).unwrap();
        assert!(done.contains("Speaker 1\t2\t1.00 0.06\nSpeaker 2\t1\t0.06 1.00\n"), "{done}");
        // Turn 0 was never fingerprinted, so it isn't compared.
        assert!(done.contains("1\t1.00 0.10 0.97\n2\t0.10 1.00 0.02\n3\t0.97 0.02 1.00\n"), "{done}");

        let left = std::fs::read_dir(&folder).unwrap().count();
        assert_eq!(left, DIAGNOSTICS_KEPT + 1, "ten diagnostics files and the unrelated one");
        assert!(folder.join("unrelated.txt").exists());
    }

    #[test]
    fn no_labeller_without_a_model() {
        assert!(voice_labeller(None, None).is_none());
        assert!(voice_labeller(Some(Path::new("/nonexistent/speaker.onnx")), None).is_none());
        // A stub of a file (an interrupted download) doesn't count as a model.
        let dir = tempfile::tempdir().unwrap();
        let stub = dir.path().join("speaker.onnx");
        std::fs::write(&stub, b"not a model").unwrap();
        assert!(voice_labeller(Some(&stub), None).is_none());
        assert!(voice_labeller(Some(dir.path()), None).is_none());
    }

    /// Not run by default: needs the model and some clips. Prints how real
    /// voices score against each other and how the labeller groups them, for
    /// choosing SPEAKER_MATCH_THRESHOLD.
    ///
    ///   FNSPEAK_SPEAKER_MODEL=/path/to/model.onnx FNSPEAK_SPEAKER_CLIPS=/folder/of/wavs \
    ///     cargo test -p fnspeak-core --features parakeet real_clips -- --ignored --nocapture
    ///
    /// Clips are 16 kHz mono 16-bit WAVs named `<speaker>-<anything>.wav`.
    /// FNSPEAK_SPEAKER_CLIP_MS cuts them into pieces of that length first,
    /// to see how short turns score.
    #[cfg(feature = "parakeet")]
    #[test]
    #[ignore]
    fn real_clips_group_by_speaker() {
        let (Ok(model), Ok(clips)) = (std::env::var("FNSPEAK_SPEAKER_MODEL"), std::env::var("FNSPEAK_SPEAKER_CLIPS")) else {
            panic!("set FNSPEAK_SPEAKER_MODEL and FNSPEAK_SPEAKER_CLIPS");
        };
        let piece_ms: Option<usize> = std::env::var("FNSPEAK_SPEAKER_CLIP_MS").ok().and_then(|v| v.parse().ok());
        let mut files: Vec<_> = std::fs::read_dir(&clips).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|e| e == "wav")).collect();
        files.sort();

        // (speaker, clip name, audio)
        let mut turns: Vec<(String, String, Vec<f32>)> = Vec::new();
        for file in &files {
            let name = file.file_stem().unwrap().to_string_lossy().into_owned();
            let who = name.split('-').next().unwrap().to_string();
            let audio = read_wav(file);
            match piece_ms {
                Some(ms) => {
                    let len = ms * SAMPLE_RATE as usize / 1000;
                    for (i, piece) in audio.chunks(len).filter(|c| c.len() == len).enumerate() {
                        turns.push((who.clone(), format!("{name}#{i}"), piece.to_vec()));
                    }
                }
                None => turns.push((who, name, audio)),
            }
        }
        assert!(!turns.is_empty(), "no clips in {clips}");

        let mut embedder = SherpaEmbedder::new(&model);
        let started = std::time::Instant::now();
        let embeddings: Vec<Vec<f32>> = turns.iter().map(|t| embedder.embed(&t.2).and_then(normalized).expect("embedding")).collect();
        let seconds: f32 = turns.iter().map(|t| t.2.len() as f32 / SAMPLE_RATE as f32).sum();
        println!("{} turns, {seconds:.0} s of audio, fingerprinted in {:?} (model load included), {} dims", turns.len(), started.elapsed(), embeddings[0].len());

        let (mut same, mut different) = (Vec::new(), Vec::new());
        for i in 0..turns.len() {
            for j in i + 1..turns.len() {
                let score = cosine(&embeddings[i], &embeddings[j]);
                if turns[i].0 == turns[j].0 { same.push(score) } else { different.push(score) }
            }
        }
        let range = |v: &mut Vec<f32>| {
            v.sort_by(f32::total_cmp);
            if v.is_empty() { "none".to_string() } else { format!("min {:.2}  median {:.2}  max {:.2}  (n={})", v[0], v[v.len() / 2], v[v.len() - 1], v.len()) }
        };
        println!("same speaker:      {}", range(&mut same));
        println!("different speaker: {}", range(&mut different));
        println!("below threshold {SPEAKER_MATCH_THRESHOLD} among same: {}, at or above among different: {}",
            same.iter().filter(|s| **s < SPEAKER_MATCH_THRESHOLD).count(), different.iter().filter(|s| **s >= SPEAKER_MATCH_THRESHOLD).count());

        // Take turns round-robin across speakers, the way a conversation goes.
        let mut by_speaker: std::collections::BTreeMap<&str, Vec<usize>> = Default::default();
        for (i, t) in turns.iter().enumerate() {
            by_speaker.entry(&t.0).or_default().push(i);
        }
        let longest = by_speaker.values().map(Vec::len).max().unwrap();
        let order: Vec<usize> = (0..longest).flat_map(|n| by_speaker.values().filter_map(move |v| v.get(n).copied())).collect();

        let mut labeller = voice_labeller(Some(Path::new(&model)), std::env::var("FNSPEAK_SPEAKER_DIAGNOSTICS").ok().map(PathBuf::from)).expect("the model file should be accepted");
        let mut seen: std::collections::BTreeMap<&str, std::collections::BTreeMap<String, usize>> = Default::default();
        for i in order {
            let label = labeller.label(&turns[i].2, 0).unwrap_or_else(|| "others".into());
            *seen.entry(&turns[i].0).or_default().entry(label).or_default() += 1;
        }
        for (who, labels) in &seen {
            println!("{who:>12}: {labels:?}");
        }
        labeller.finish();
        println!("{} voices found for {} speakers", labeller.voices().len(), by_speaker.len());
        if piece_ms.is_none() {
            assert_eq!(labeller.voices().len(), by_speaker.len());
        }
    }

    #[cfg(feature = "parakeet")]
    fn read_wav(path: &Path) -> Vec<f32> {
        let bytes = std::fs::read(path).unwrap();
        assert_eq!(&bytes[..4], b"RIFF", "{} is not a WAV", path.display());
        let mut at = 12;
        while at + 8 <= bytes.len() {
            let len = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().unwrap()) as usize;
            let body = &bytes[at + 8..(at + 8 + len).min(bytes.len())];
            if &bytes[at..at + 4] == b"fmt " {
                let (channels, rate, bits) = (u16::from_le_bytes([body[2], body[3]]), u32::from_le_bytes(body[4..8].try_into().unwrap()), u16::from_le_bytes([body[14], body[15]]));
                assert_eq!((channels, rate, bits), (1, SAMPLE_RATE, 16), "{} must be 16 kHz mono 16-bit", path.display());
            }
            if &bytes[at..at + 4] == b"data" {
                return body.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0).collect();
            }
            at += 8 + len + len % 2;
        }
        panic!("no audio in {}", path.display());
    }
}
