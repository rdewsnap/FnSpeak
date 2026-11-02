//! The whole dictation path: audio → speech-to-text → rule-based filter →
//! vocabulary fixes → cleanup model → guardrail → text to insert.
//!
//! Every step after speech-to-text has a safe fallback, so a slow or failing
//! cleanup model never loses a dictation: the user gets the filtered text.

use crate::cleanup::{guardrail, trim_expanded_terms, Cleaner, CleanupMode, CleanupRequest};
use crate::context::DictationContext;
use crate::filter::filter;
use crate::history::History;
use crate::stt::{is_silent, sanitize, SttEngine, SttError, SttHints, SAMPLE_RATE};
use crate::vocab::{apply_corrections, apply_suggestions, VocabIndex, AUTO_APPLY_SCORE};
use serde::{Deserialize, Serialize};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// Terms passed to the speech engine and the cleanup model per dictation.
const VOCAB_PER_DICTATION: usize = 40;

#[derive(Debug, thiserror::Error)]
pub enum PipelineError {
    #[error(transparent)]
    Stt(#[from] SttError),
    #[error("vocabulary error: {0}")]
    Vocab(#[from] crate::vocab::VocabError),
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Timings {
    pub stt_ms: u64,
    pub cleanup_ms: u64,
    pub total_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DictationResult {
    /// Exactly what the speech engine heard.
    pub raw: String,
    /// After the rule-based filter and high-confidence vocabulary fixes.
    pub filtered: String,
    /// The cleaned text, before adjusting it to the cursor position.
    pub text: String,
    /// What to insert at the cursor (spacing and capitalization adjusted).
    pub insert: String,
    pub mode: CleanupMode,
    /// Which cleanup model produced `text`, if one did.
    pub cleaner: Option<String>,
    /// Why the cleanup model's output wasn't used, if it wasn't.
    pub fallback_reason: Option<String>,
    pub timings: Timings,
}

pub struct Pipeline {
    stt: Box<dyn SttEngine>,
    cleaner: Option<Box<dyn Cleaner>>,
    pub vocab: VocabIndex,
    pub history: Option<History>,
    pub mode: CleanupMode,
}

impl Pipeline {
    pub fn new(stt: Box<dyn SttEngine>, vocab: VocabIndex, mode: CleanupMode) -> Self {
        Pipeline { stt, cleaner: None, vocab, history: None, mode }
    }

    pub fn with_cleaner(mut self, cleaner: Box<dyn Cleaner>) -> Self {
        self.cleaner = Some(cleaner);
        self
    }

    pub fn with_history(mut self, history: History) -> Self {
        self.history = Some(history);
        self
    }

    pub fn set_cleaner(&mut self, cleaner: Option<Box<dyn Cleaner>>) {
        self.cleaner = cleaner;
    }

    pub fn set_stt(&mut self, stt: Box<dyn SttEngine>) {
        self.stt = stt;
    }

    pub fn stt_name(&self) -> &'static str {
        self.stt.name()
    }

    /// Run a recorded clip (16 kHz mono f32) through the whole pipeline.
    pub fn dictate(&mut self, audio: &[f32], ctx: &DictationContext) -> Result<DictationResult, PipelineError> {
        let started = Instant::now();
        let seconds = audio.len() as f32 / SAMPLE_RATE as f32;

        let raw = if is_silent(audio) {
            String::new()
        } else {
            let hints = SttHints { vocabulary: self.vocab.relevant_terms(&ctx.searchable(), &[], VOCAB_PER_DICTATION)? };
            sanitize(&self.stt.transcribe(audio, &hints)?, seconds)
        };
        let stt_ms = started.elapsed().as_millis() as u64;

        let mut result = self.clean(&raw, ctx)?;
        result.timings.stt_ms = stt_ms;
        result.timings.total_ms = started.elapsed().as_millis() as u64;
        self.record(&result, ctx, (seconds * 1000.0) as i64);
        Ok(result)
    }

    /// Everything after speech-to-text. Also used by the benchmark to score
    /// transcripts that came from elsewhere.
    pub fn clean(&mut self, raw: &str, ctx: &DictationContext) -> Result<DictationResult, PipelineError> {
        let started = Instant::now();
        let mut result = DictationResult {
            raw: raw.to_string(),
            filtered: String::new(),
            text: String::new(),
            insert: String::new(),
            mode: self.mode,
            cleaner: None,
            fallback_reason: None,
            timings: Timings::default(),
        };
        if raw.trim().is_empty() {
            return Ok(result);
        }
        if self.mode == CleanupMode::Raw {
            result.filtered = raw.to_string();
            result.text = raw.to_string();
            result.insert = fit_to_cursor(&result.text, ctx);
            return Ok(result);
        }

        let filtered = filter(raw);
        let suggestions = self.vocab.suggest(&filtered)?;
        let corrections = self.vocab.corrections()?;
        result.filtered = apply_corrections(&apply_suggestions(&filtered, &suggestions, AUTO_APPLY_SCORE), &corrections);
        result.text = result.filtered.clone();

        let wants_model = matches!(self.mode, CleanupMode::Local | CleanupMode::Cloud);
        match self.cleaner.as_mut() {
            Some(cleaner) if wants_model && !filtered.is_empty() => {
                let mut vocabulary = self.vocab.relevant_terms(&ctx.searchable(), &suggestions, VOCAB_PER_DICTATION)?;
                // Learned spellings in this dictation count as vocabulary, so
                // the guardrail accepts them and the model sees them.
                for c in corrections.iter().filter(|c| result.filtered.contains(c.corrected.as_str())) {
                    if !vocabulary.contains(&c.corrected) {
                        vocabulary.push(c.corrected.clone());
                    }
                }
                let req = CleanupRequest { transcript: &filtered, context: ctx, vocabulary: &vocabulary, suggestions: &suggestions };
                let cleaned = cleaner.clean(&req).and_then(|out| guardrail(&filtered, &out, &vocabulary).map(|_| out));
                match cleaned {
                    Ok(text) => {
                        // Again on the model's output: it works from the
                        // unfixed transcript and may keep what was misheard.
                        result.text = apply_corrections(&trim_expanded_terms(&filtered, &text, &vocabulary), &corrections);
                        result.cleaner = Some(cleaner.name());
                    }
                    Err(e) => result.fallback_reason = Some(e.to_string()),
                }
            }
            None if wants_model => result.fallback_reason = Some("no cleanup model configured".into()),
            _ => {}
        }

        result.timings.cleanup_ms = started.elapsed().as_millis() as u64;
        result.insert = fit_to_cursor(&result.text, ctx);
        Ok(result)
    }

    fn record(&mut self, result: &DictationResult, ctx: &DictationContext, duration_ms: i64) {
        if result.text.is_empty() {
            return;
        }
        // Bookkeeping must never fail a dictation.
        let _ = self.vocab.record_usage(&result.text);
        if let Some(history) = &self.history {
            let mode = serde_json::to_value(result.mode).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default();
            let _ = history.save(now(), &ctx.app_id, &result.raw, &result.text, &mode, duration_ms);
        }
    }
}

/// Words that only start with a capital because they started the dictation.
const LOWERCASE_MID_SENTENCE: &[&str] = &[
    "a", "an", "the", "and", "but", "or", "so", "then", "also", "because", "which", "that", "this", "these",
    "those", "it", "its", "we", "you", "they", "he", "she", "to", "for", "with", "in", "on", "at", "of",
    "if", "when", "while", "maybe", "just", "not", "is", "are", "was", "were", "can", "will", "should",
    "would", "could", "my", "our", "your", "their", "there", "here", "what", "how", "why",
];

/// Adjust cleaned text to where it's being inserted: add a separating space
/// after existing text, and don't capitalize a continuation mid-sentence.
pub fn fit_to_cursor(text: &str, ctx: &DictationContext) -> String {
    let before = ctx.text_before.as_str();
    let Some(last) = before.chars().next_back() else {
        return text.to_string();
    };
    let mut out = String::with_capacity(text.len() + 1);
    let needs_space = !last.is_whitespace() && text.chars().next().is_some_and(|c| c.is_alphanumeric());
    if needs_space {
        out.push(' ');
    }

    let mid_sentence = before.trim_end().chars().next_back().is_some_and(|c| !matches!(c, '.' | '!' | '?' | ':' | '\n'));
    let first_word: String = text.chars().take_while(|c| c.is_alphabetic()).collect();
    if mid_sentence && LOWERCASE_MID_SENTENCE.contains(&first_word.to_lowercase().as_str()) && !text.contains('\n') {
        let mut chars = text.chars();
        if let Some(c) = chars.next() {
            out.extend(c.to_lowercase());
            out.push_str(chars.as_str());
            // A single mid-sentence clause shouldn't get a period it didn't have.
            return out;
        }
    }
    out.push_str(text);
    out
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cleanup::CleanupError;
    use crate::stt::FixedTranscript;
    use crate::vocab::Source;

    struct Echo(&'static str);
    impl Cleaner for Echo {
        fn name(&self) -> String {
            "echo".into()
        }
        fn clean(&mut self, _req: &CleanupRequest<'_>) -> Result<String, CleanupError> {
            Ok(self.0.to_string())
        }
    }

    fn pipeline(transcript: &str, mode: CleanupMode) -> Pipeline {
        let mut vocab = VocabIndex::in_memory().unwrap();
        vocab.add_terms(Source::Project, ["Kinju"]).unwrap();
        Pipeline::new(Box::new(FixedTranscript(transcript.into())), vocab, mode)
    }

    fn speech() -> Vec<f32> {
        (0..16_000).map(|i| (i as f32 * 0.05).sin() * 0.2).collect()
    }

    #[test]
    fn filter_only_applies_filter_and_vocab() {
        let mut p = pipeline("um so the kin ju build is is green", CleanupMode::FilterOnly);
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "So the Kinju build is green");
        assert!(r.fallback_reason.is_none());
    }

    #[test]
    fn uses_model_output_when_guardrail_passes() {
        let mut p = pipeline("send it to Sam actually Priya", CleanupMode::Cloud).with_cleaner(Box::new(Echo("Send it to Priya.")));
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "Send it to Priya.");
        assert_eq!(r.cleaner.as_deref(), Some("echo"));
    }

    #[test]
    fn falls_back_when_model_invents_text() {
        let mut p = pipeline("what's the weather like in Paris today", CleanupMode::Cloud)
            .with_cleaner(Box::new(Echo("It is sunny and warm in Paris with highs around twenty five degrees all week.")));
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "what's the weather like in Paris today");
        assert!(r.fallback_reason.unwrap().contains("rejected"));
    }

    #[test]
    fn applies_learned_corrections_without_a_model() {
        let mut p = pipeline("ask priya to review the PG vector change", CleanupMode::FilterOnly);
        p.vocab.learn_from_edit("Ask Priya to review it.", "Ask Pria to review it.").unwrap();
        p.vocab.record_correction("pg vector", "pgvector").unwrap();
        p.vocab.record_correction("pg vector", "pgvector").unwrap();
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "ask Pria to review the pgvector change");
    }

    #[test]
    fn learned_corrections_survive_the_model() {
        let mut p = pipeline("um tell kenju the build is green", CleanupMode::Cloud)
            .with_cleaner(Box::new(Echo("Tell Kenju the build is green.")));
        p.vocab.learn_from_edit("Tell Kenju hi.", "Tell Kinju hi.").unwrap();
        let r = p.dictate(&speech(), &DictationContext::default()).unwrap();
        assert_eq!(r.text, "Tell Kinju the build is green.");
        assert_eq!(r.cleaner.as_deref(), Some("echo"));
    }

    #[test]
    fn raw_mode_skips_everything() {
        let mut p = pipeline("um hello", CleanupMode::Raw);
        assert_eq!(p.dictate(&speech(), &DictationContext::default()).unwrap().text, "um hello");
    }

    #[test]
    fn silence_produces_nothing() {
        let mut p = pipeline("Thank you.", CleanupMode::FilterOnly);
        let r = p.dictate(&vec![0.0; 16_000], &DictationContext::default()).unwrap();
        assert_eq!(r.insert, "");
    }

    #[test]
    fn records_history() {
        let mut p = pipeline("ship it", CleanupMode::FilterOnly).with_history(History::in_memory().unwrap());
        p.dictate(&speech(), &DictationContext { app_id: "com.apple.mail".into(), ..Default::default() }).unwrap();
        let last = p.history.as_ref().unwrap().last().unwrap().unwrap();
        assert_eq!((last.raw.as_str(), last.mode.as_str()), ("ship it", "filter_only"));
    }

    #[test]
    fn fits_text_to_cursor() {
        let ctx = |before: &str| DictationContext { text_before: before.into(), ..Default::default() };
        assert_eq!(fit_to_cursor("We should ship.", &ctx("")), "We should ship.");
        assert_eq!(fit_to_cursor("We should ship.", &ctx("Done.")), " We should ship.");
        assert_eq!(fit_to_cursor("We should ship.", &ctx("Done. ")), "We should ship.");
        assert_eq!(fit_to_cursor("We should ship", &ctx("I think ")), "we should ship");
        assert_eq!(fit_to_cursor("Priya agreed", &ctx("and then ")), "Priya agreed");
    }
}
