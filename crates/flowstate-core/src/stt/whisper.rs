use super::{SttEngine, SttError, SttHints};
use std::path::PathBuf;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState};

/// Whisper's prompt window is 224 tokens; stay well inside it.
const PROMPT_CHAR_BUDGET: usize = 600;

/// How much of the text before a chunk goes into its prompt. Enough for a
/// sentence or two of context; the rest of the budget stays for vocabulary.
const PRECEDING_CHAR_BUDGET: usize = 200;

#[derive(Clone, Debug)]
pub struct WhisperConfig {
    /// Path to a ggml model, e.g. `ggml-large-v3-turbo-q5_0.bin`.
    pub model_path: PathBuf,
    pub threads: i32,
    /// Beam search is slower but noticeably better with an initial prompt.
    pub beam_size: i32,
    pub use_gpu: bool,
}

impl WhisperConfig {
    pub fn new(model_path: impl Into<PathBuf>) -> Self {
        WhisperConfig {
            model_path: model_path.into(),
            threads: std::thread::available_parallelism().map(|n| n.get().min(8) as i32).unwrap_or(4),
            beam_size: 5,
            use_gpu: true,
        }
    }
}

pub struct WhisperEngine {
    config: WhisperConfig,
    // Keeps the model alive for the state.
    _ctx: WhisperContext,
    state: WhisperState,
}

impl WhisperEngine {
    pub fn load(config: WhisperConfig) -> Result<Self, SttError> {
        let mut params = WhisperContextParameters::default();
        params.use_gpu(config.use_gpu);
        let ctx = WhisperContext::new_with_params(&config.model_path, params)
            .map_err(|e| SttError::Load(format!("{}: {e}", config.model_path.display())))?;
        let state = ctx.create_state().map_err(|e| SttError::Load(e.to_string()))?;
        Ok(WhisperEngine { config, _ctx: ctx, state })
    }
}

/// Build the starting prompt. Whisper copies the prompt's style, so a short,
/// properly punctuated sentence works better than a bare word list. Text
/// from earlier in the same dictation goes last, right before the audio,
/// which is where Whisper expects what was just said.
pub(crate) fn build_prompt(vocabulary: &[String], preceding: &str) -> String {
    let tail = preceding_tail(preceding);
    let vocab_budget = if tail.is_empty() { PROMPT_CHAR_BUDGET } else { PROMPT_CHAR_BUDGET - tail.len() - 1 };
    let mut prompt = String::new();
    if !vocabulary.is_empty() {
        prompt.push_str("Names and terms:");
        for (i, term) in vocabulary.iter().enumerate() {
            let piece = if i == 0 { format!(" {term}") } else { format!(", {term}") };
            if prompt.len() + piece.len() + 1 > vocab_budget {
                break;
            }
            prompt.push_str(&piece);
        }
        prompt.push('.');
    }
    if !tail.is_empty() {
        if !prompt.is_empty() {
            prompt.push(' ');
        }
        prompt.push_str(tail);
    }
    prompt
}

/// The last `PRECEDING_CHAR_BUDGET` bytes of `text`, starting at a word.
fn preceding_tail(text: &str) -> &str {
    let text = text.trim();
    if text.len() <= PRECEDING_CHAR_BUDGET {
        return text;
    }
    let mut start = text.len() - PRECEDING_CHAR_BUDGET;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    let cut = &text[start..];
    match cut.find(char::is_whitespace) {
        Some(i) => cut[i..].trim_start(),
        None => cut,
    }
}

impl SttEngine for WhisperEngine {
    fn name(&self) -> &'static str {
        "whisper"
    }

    fn transcribe(&mut self, audio: &[f32], hints: &SttHints) -> Result<String, SttError> {
        self.transcribe_continuing(audio, hints, "")
    }

    fn transcribe_continuing(&mut self, audio: &[f32], hints: &SttHints, preceding: &str) -> Result<String, SttError> {
        let strategy = if self.config.beam_size > 1 {
            SamplingStrategy::BeamSearch { beam_size: self.config.beam_size, patience: -1.0 }
        } else {
            SamplingStrategy::Greedy { best_of: 1 }
        };
        let mut params = FullParams::new(strategy);
        params.set_language(Some("en"));
        params.set_n_threads(self.config.threads);
        params.set_no_context(true);
        params.set_suppress_blank(true);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);

        let prompt = Some(build_prompt(&hints.vocabulary, preceding)).filter(|p| !p.is_empty());
        if let Some(prompt) = &prompt {
            params.set_initial_prompt(prompt);
        }

        self.state.full(params, audio).map_err(|e| SttError::Transcribe(e.to_string()))?;

        let mut text = String::new();
        for segment in self.state.as_iter() {
            let piece = segment.to_str_lossy().map_err(|e| SttError::Transcribe(e.to_string()))?;
            text.push_str(&piece);
        }
        let text = text.trim().to_string();

        // Whisper sometimes repeats its prompt back when it hears nothing useful.
        let echoed = prompt.as_deref().is_some_and(|p| text == p || text.starts_with("Names and terms:"));
        if echoed || (!preceding.is_empty() && text == preceding_tail(preceding)) {
            return Ok(String::new());
        }
        Ok(text)
    }
}

#[cfg(test)]
mod tests {
    use super::{build_prompt, PRECEDING_CHAR_BUDGET, PROMPT_CHAR_BUDGET};

    #[test]
    fn prompt_fits_budget() {
        let vocab: Vec<String> = (0..500).map(|i| format!("Term{i}")).collect();
        let p = build_prompt(&vocab, "");
        assert!(p.len() <= PROMPT_CHAR_BUDGET);
        assert!(p.starts_with("Names and terms: Term0, Term1"));
        assert!(p.ends_with('.'));
    }

    #[test]
    fn prompt_ends_with_preceding_text() {
        let vocab: Vec<String> = (0..500).map(|i| format!("Term{i}")).collect();
        let preceding = "word ".repeat(100) + "and then we shipped it.";
        let p = build_prompt(&vocab, &preceding);
        assert!(p.len() <= PROMPT_CHAR_BUDGET);
        assert!(p.starts_with("Names and terms: Term0"));
        assert!(p.ends_with(" word and then we shipped it."));
        let tail = p.rsplit_once(". ").unwrap().1;
        assert!(tail.len() <= PRECEDING_CHAR_BUDGET && tail.starts_with("word"));

        assert_eq!(build_prompt(&[], "Hello there."), "Hello there.");
        assert_eq!(build_prompt(&[], ""), "");
    }
}
