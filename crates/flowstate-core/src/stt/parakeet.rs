use super::{SttEngine, SttError, SttHints, SAMPLE_RATE};
use sherpa_rs::transducer::{TransducerConfig, TransducerRecognizer};
use std::io::Write;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct ParakeetConfig {
    /// Folder with the sherpa-onnx export of Parakeet TDT
    /// (`encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt`).
    pub model_dir: PathBuf,
    pub threads: i32,
    /// Experimental: boost vocabulary terms during decoding. Needs
    /// `bpe.vocab` in the model folder and modified beam search; the
    /// benchmark should confirm it helps before it's turned on by default.
    pub hotwords: bool,
    pub hotwords_score: f32,
    /// e.g. "cuda" on Windows with an NVIDIA GPU; defaults to CPU.
    pub provider: Option<String>,
}

impl ParakeetConfig {
    pub fn new(model_dir: impl Into<PathBuf>) -> Self {
        ParakeetConfig {
            model_dir: model_dir.into(),
            threads: std::thread::available_parallelism().map(|n| n.get().min(8) as i32).unwrap_or(4),
            hotwords: false,
            hotwords_score: 1.5,
            provider: None,
        }
    }
}

pub struct ParakeetEngine {
    config: ParakeetConfig,
    recognizer: TransducerRecognizer,
    /// Vocabulary the recognizer was last built with (hotwords are fixed at load).
    loaded_hotwords: Vec<String>,
}

// The recognizer is a raw pointer to a sherpa-onnx object that isn't tied to
// a thread; the pipeline only ever uses it from one thread at a time.
unsafe impl Send for ParakeetEngine {}

impl ParakeetEngine {
    pub fn load(config: ParakeetConfig) -> Result<Self, SttError> {
        let recognizer = build(&config, &[])?;
        Ok(ParakeetEngine { config, recognizer, loaded_hotwords: Vec::new() })
    }
}

fn find(dir: &Path, stem: &str) -> Result<String, SttError> {
    for name in [format!("{stem}.int8.onnx"), format!("{stem}.onnx")] {
        let path = dir.join(&name);
        if path.exists() {
            return Ok(path.to_string_lossy().into_owned());
        }
    }
    Err(SttError::Load(format!("no {stem}.onnx in {}", dir.display())))
}

fn build(config: &ParakeetConfig, hotwords: &[String]) -> Result<TransducerRecognizer, SttError> {
    let dir = &config.model_dir;
    let tokens = dir.join("tokens.txt");
    if !tokens.exists() {
        return Err(SttError::Load(format!("no tokens.txt in {}", dir.display())));
    }
    let mut cfg = TransducerConfig {
        encoder: find(dir, "encoder")?,
        decoder: find(dir, "decoder")?,
        joiner: find(dir, "joiner")?,
        tokens: tokens.to_string_lossy().into_owned(),
        num_threads: config.threads,
        sample_rate: SAMPLE_RATE as i32,
        feature_dim: 80,
        model_type: "nemo_transducer".into(),
        decoding_method: "greedy_search".into(),
        provider: config.provider.clone(),
        ..Default::default()
    };

    let bpe_vocab = dir.join("bpe.vocab");
    if config.hotwords && !hotwords.is_empty() && bpe_vocab.exists() {
        let path = std::env::temp_dir().join("flowstate-hotwords.txt");
        let mut f = std::fs::File::create(&path).map_err(|e| SttError::Load(e.to_string()))?;
        for word in hotwords {
            writeln!(f, "{}", word.to_uppercase()).map_err(|e| SttError::Load(e.to_string()))?;
        }
        cfg.hotwords_file = path.to_string_lossy().into_owned();
        cfg.hotwords_score = config.hotwords_score;
        cfg.decoding_method = "modified_beam_search".into();
        cfg.modeling_unit = "bpe".into();
        cfg.bpe_vocab = bpe_vocab.to_string_lossy().into_owned();
    }

    TransducerRecognizer::new(cfg).map_err(|e| SttError::Load(e.to_string()))
}

impl SttEngine for ParakeetEngine {
    fn name(&self) -> &'static str {
        "parakeet"
    }

    fn transcribe(&mut self, audio: &[f32], hints: &SttHints) -> Result<String, SttError> {
        if self.config.hotwords && hints.vocabulary != self.loaded_hotwords {
            self.recognizer = build(&self.config, &hints.vocabulary)?;
            self.loaded_hotwords = hints.vocabulary.clone();
        }
        Ok(self.recognizer.transcribe(SAMPLE_RATE, audio).trim().to_string())
    }
}
