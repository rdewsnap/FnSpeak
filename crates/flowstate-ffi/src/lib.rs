//! The surface the native shells talk to. Swift bindings are generated with
//! `uniffi-bindgen` (see `scripts/build-mac.sh`); a C# binding can come from
//! the same definitions when the Windows shell lands.

use flowstate_core::cleanup::{AnthropicCleaner, Cleaner, LocalCleaner, LocalConfig, OpenAiCompatCleaner, RoutedCleaner};
use flowstate_core::history::History;
use flowstate_core::stt::SttEngine;
use flowstate_core::tier::HardwareInfo;
use flowstate_core::vocab::{self, VocabIndex};
use flowstate_core::{CleanupMode, DictationContext, Pipeline};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FlowstateError {
    #[error("{0}")]
    Setup(String),
    #[error("{0}")]
    Dictation(String),
    #[error("{0}")]
    Storage(String),
}

fn setup_err(e: impl std::fmt::Display) -> FlowstateError {
    FlowstateError::Setup(e.to_string())
}

fn storage_err(e: impl std::fmt::Display) -> FlowstateError {
    FlowstateError::Storage(e.to_string())
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum Mode {
    Local,
    Cloud,
    FilterOnly,
    Raw,
}

impl From<Mode> for CleanupMode {
    fn from(m: Mode) -> Self {
        match m {
            Mode::Local => CleanupMode::Local,
            Mode::Cloud => CleanupMode::Cloud,
            Mode::FilterOnly => CleanupMode::FilterOnly,
            Mode::Raw => CleanupMode::Raw,
        }
    }
}

impl From<CleanupMode> for Mode {
    fn from(m: CleanupMode) -> Self {
        match m {
            CleanupMode::Local => Mode::Local,
            CleanupMode::Cloud => Mode::Cloud,
            CleanupMode::FilterOnly => Mode::FilterOnly,
            CleanupMode::Raw => Mode::Raw,
        }
    }
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum SpeechEngine {
    Whisper { model_path: String },
    Parakeet { model_dir: String },
}

#[derive(Clone, Debug, uniffi::Enum)]
pub enum CloudProvider {
    Anthropic,
    /// Groq, OpenRouter, OpenAI, Ollama, LM Studio, Flowstate Cloud.
    OpenAiCompatible { base_url: String },
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudConfig {
    pub provider: CloudProvider,
    pub api_key: Option<String>,
    /// Model for dictations with self-corrections.
    pub model: String,
    /// Cheaper model for everything else; same as `model` when unset.
    pub light_model: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LocalModel {
    /// The `llama-server` binary, usually bundled in the app.
    pub server_binary: String,
    /// GGUF cleanup model.
    pub model_path: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct EngineConfig {
    /// Where the vocabulary and history databases live.
    pub data_dir: String,
    pub speech: SpeechEngine,
    pub mode: Mode,
    pub local: Option<LocalModel>,
    pub cloud: Option<CloudConfig>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Context {
    pub app_id: String,
    pub app_name: String,
    pub window_title: String,
    pub url: Option<String>,
    pub text_before: String,
}

impl From<Context> for DictationContext {
    fn from(c: Context) -> Self {
        DictationContext { app_id: c.app_id, app_name: c.app_name, window_title: c.window_title, url: c.url, text_before: c.text_before }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Dictation {
    pub raw: String,
    pub text: String,
    /// What to insert at the cursor.
    pub insert: String,
    pub mode: Mode,
    pub cleaner: Option<String>,
    pub fallback_reason: Option<String>,
    pub stt_ms: u64,
    pub cleanup_ms: u64,
    pub total_ms: u64,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum TermSource {
    Project,
    Contact,
    Calendar,
    User,
    Correction,
}

impl From<TermSource> for vocab::Source {
    fn from(s: TermSource) -> Self {
        match s {
            TermSource::Project => vocab::Source::Project,
            TermSource::Contact => vocab::Source::Contact,
            TermSource::Calendar => vocab::Source::Calendar,
            TermSource::User => vocab::Source::User,
            TermSource::Correction => vocab::Source::Correction,
        }
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Term {
    pub text: String,
    pub source: String,
    pub hits: i64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Hardware {
    pub total_memory_gb: f64,
    pub apple_silicon: bool,
    pub gpu_memory_gb: Option<f64>,
    pub recommended_mode: Mode,
}

/// First-run hardware check. The shell can add GPU memory on Windows and
/// call `recommended_mode_for` again.
#[uniffi::export]
pub fn detect_hardware() -> Hardware {
    let hw = HardwareInfo::detect();
    Hardware {
        total_memory_gb: hw.total_memory_gb,
        apple_silicon: hw.apple_silicon,
        gpu_memory_gb: hw.gpu_memory_gb,
        recommended_mode: hw.default_cleanup_mode().into(),
    }
}

#[uniffi::export]
pub fn recommended_mode_for(total_memory_gb: f64, apple_silicon: bool, gpu_memory_gb: Option<f64>, measured_tokens_per_sec: Option<f64>) -> Mode {
    HardwareInfo { total_memory_gb, apple_silicon, gpu_memory_gb, measured_tokens_per_sec }.default_cleanup_mode().into()
}

/// Terms from a projects folder (project, package and README names).
#[uniffi::export]
pub fn scan_projects(root: String) -> Result<Vec<String>, FlowstateError> {
    vocab::projects::index_projects(Path::new(&root)).map_err(storage_err)
}

#[derive(uniffi::Object)]
pub struct FlowstateEngine {
    pipeline: Mutex<Pipeline>,
}

#[uniffi::export]
impl FlowstateEngine {
    #[uniffi::constructor]
    pub fn new(config: EngineConfig) -> Result<Arc<Self>, FlowstateError> {
        let dir = PathBuf::from(&config.data_dir);
        std::fs::create_dir_all(&dir).map_err(storage_err)?;
        let vocab = VocabIndex::open(dir.join("vocabulary.db")).map_err(storage_err)?;
        let history = History::open(dir.join("history.db")).map_err(storage_err)?;

        let mut pipeline = Pipeline::new(build_stt(&config.speech)?, vocab, config.mode.into()).with_history(history);
        pipeline.set_cleaner(build_cleaner(config.mode.into(), config.local.as_ref(), config.cloud.as_ref())?);
        Ok(Arc::new(FlowstateEngine { pipeline: Mutex::new(pipeline) }))
    }

    /// Transcribe and clean a clip of 16 kHz mono f32 samples.
    pub fn dictate(&self, audio: Vec<f32>, context: Context) -> Result<Dictation, FlowstateError> {
        let mut p = self.pipeline.lock().unwrap();
        let r = p.dictate(&audio, &context.into()).map_err(|e| FlowstateError::Dictation(e.to_string()))?;
        Ok(Dictation {
            raw: r.raw,
            text: r.text,
            insert: r.insert,
            mode: r.mode.into(),
            cleaner: r.cleaner,
            fallback_reason: r.fallback_reason,
            stt_ms: r.timings.stt_ms,
            cleanup_ms: r.timings.cleanup_ms,
            total_ms: r.timings.total_ms,
        })
    }

    /// Switch cleanup mode or models without reloading the speech engine.
    pub fn configure_cleanup(&self, mode: Mode, local: Option<LocalModel>, cloud: Option<CloudConfig>) -> Result<(), FlowstateError> {
        let cleaner = build_cleaner(mode.into(), local.as_ref(), cloud.as_ref())?;
        let mut p = self.pipeline.lock().unwrap();
        p.mode = mode.into();
        p.set_cleaner(cleaner);
        Ok(())
    }

    pub fn set_speech_engine(&self, speech: SpeechEngine) -> Result<(), FlowstateError> {
        let stt = build_stt(&speech)?;
        self.pipeline.lock().unwrap().set_stt(stt);
        Ok(())
    }

    pub fn add_terms(&self, source: TermSource, terms: Vec<String>) -> Result<u32, FlowstateError> {
        let mut p = self.pipeline.lock().unwrap();
        p.vocab.add_terms(source.into(), terms).map(|n| n as u32).map_err(storage_err)
    }

    /// Replace every term from a source, e.g. after re-reading contacts.
    pub fn replace_terms(&self, source: TermSource, terms: Vec<String>) -> Result<u32, FlowstateError> {
        let mut p = self.pipeline.lock().unwrap();
        p.vocab.replace_source(source.into(), terms).map(|n| n as u32).map_err(storage_err)
    }

    pub fn remove_term(&self, term: String) -> Result<bool, FlowstateError> {
        self.pipeline.lock().unwrap().vocab.remove_term(&term).map_err(storage_err)
    }

    pub fn terms(&self) -> Result<Vec<Term>, FlowstateError> {
        let p = self.pipeline.lock().unwrap();
        let terms = p.vocab.terms(None).map_err(storage_err)?;
        Ok(terms
            .into_iter()
            .map(|t| Term {
                text: t.text,
                source: source_name(t.source),
                hits: t.hits,
            })
            .collect())
    }

    /// The user edited inserted text: learn the corrected spelling.
    pub fn record_correction(&self, heard: String, corrected: String) -> Result<(), FlowstateError> {
        self.pipeline.lock().unwrap().vocab.record_correction(&heard, &corrected).map(|_| ()).map_err(storage_err)
    }

    /// Raw transcript of the most recent dictation, for the swap-to-raw shortcut.
    pub fn last_raw(&self) -> Option<String> {
        let p = self.pipeline.lock().unwrap();
        p.history.as_ref().and_then(|h| h.last().ok().flatten()).map(|e| e.raw)
    }

    pub fn purge_history(&self, older_than_days: u32) -> Result<u32, FlowstateError> {
        let p = self.pipeline.lock().unwrap();
        let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
        match &p.history {
            Some(h) => h.purge_older_than(now, older_than_days).map(|n| n as u32).map_err(storage_err),
            None => Ok(0),
        }
    }
}

fn source_name(s: vocab::Source) -> String {
    match s {
        vocab::Source::Project => "project",
        vocab::Source::Contact => "contact",
        vocab::Source::Calendar => "calendar",
        vocab::Source::User => "user",
        vocab::Source::Correction => "correction",
        vocab::Source::Learned => "learned",
    }
    .to_string()
}

fn build_stt(speech: &SpeechEngine) -> Result<Box<dyn SttEngine>, FlowstateError> {
    match speech {
        #[cfg(feature = "whisper")]
        SpeechEngine::Whisper { model_path } => Ok(Box::new(
            flowstate_core::stt::WhisperEngine::load(flowstate_core::stt::WhisperConfig::new(model_path)).map_err(setup_err)?,
        )),
        #[cfg(feature = "parakeet")]
        SpeechEngine::Parakeet { model_dir } => Ok(Box::new(
            flowstate_core::stt::ParakeetEngine::load(flowstate_core::stt::ParakeetConfig::new(model_dir)).map_err(setup_err)?,
        )),
        #[allow(unreachable_patterns)]
        other => Err(FlowstateError::Setup(format!("{other:?} isn't compiled into this build"))),
    }
}

fn build_cleaner(mode: CleanupMode, local: Option<&LocalModel>, cloud: Option<&CloudConfig>) -> Result<Option<Box<dyn Cleaner>>, FlowstateError> {
    match mode {
        CleanupMode::Raw | CleanupMode::FilterOnly => Ok(None),
        CleanupMode::Local => {
            let local = local.ok_or_else(|| FlowstateError::Setup("local mode needs a cleanup model".into()))?;
            let cleaner = LocalCleaner::start(LocalConfig::new(&local.server_binary, &local.model_path)).map_err(setup_err)?;
            Ok(Some(Box::new(cleaner)))
        }
        CleanupMode::Cloud => {
            let cloud = cloud.ok_or_else(|| FlowstateError::Setup("cloud mode needs a provider".into()))?;
            let make = |model: &str| -> Result<Box<dyn Cleaner>, FlowstateError> {
                Ok(match &cloud.provider {
                    CloudProvider::Anthropic => Box::new(
                        AnthropicCleaner::new(cloud.api_key.clone().unwrap_or_default(), Some(model.to_string())).map_err(setup_err)?,
                    ),
                    CloudProvider::OpenAiCompatible { base_url } => {
                        Box::new(OpenAiCompatCleaner::new(base_url.clone(), cloud.api_key.clone(), model).map_err(setup_err)?)
                    }
                })
            };
            let heavy = make(&cloud.model)?;
            Ok(Some(match cloud.light_model.as_deref() {
                Some(light) if light != cloud.model => Box::new(RoutedCleaner { light: make(light)?, heavy }),
                _ => heavy,
            }))
        }
    }
}
