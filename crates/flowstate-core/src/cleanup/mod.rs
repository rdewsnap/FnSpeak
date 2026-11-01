//! The second cleanup layer: a language model that removes judgment-call
//! fillers and repairs self-corrections across the whole dictation.
//!
//! Every backend gets the same prompt (shared with the fine-tuning scripts in
//! `training/`), and every result passes through [`guardrail`] before it's
//! trusted. Anything that fails falls back to the rule-based filter output.

mod cloud;
mod local;
mod prompt;
mod route;

pub use cloud::{AnthropicCleaner, OpenAiCompatCleaner};
pub use local::{LlamaServer, LocalCleaner, LocalConfig};
pub use prompt::{build_user_message, SYSTEM_PROMPT};
pub use route::{needs_repair, RoutedCleaner};

use crate::context::DictationContext;
use crate::vocab::Suggestion;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Debug, thiserror::Error)]
pub enum CleanupError {
    #[error("cleanup model failed to load: {0}")]
    Load(String),
    #[error("cleanup request failed: {0}")]
    Request(String),
    #[error("cleanup model declined the request")]
    Refused,
    #[error("cleanup output rejected: {0}")]
    Rejected(String),
}

/// How the second layer runs. Chosen at first run from the hardware tier and
/// changeable in settings at any time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CleanupMode {
    /// Local language model.
    Local,
    /// Hosted model (Flowstate Cloud or the user's own API key). Text only;
    /// audio never leaves the machine.
    Cloud,
    /// Rule-based filter plus high-confidence vocabulary fixes. Instant.
    FilterOnly,
    /// Exactly what the speech engine heard.
    Raw,
}

pub struct CleanupRequest<'a> {
    /// Transcript after the rule-based filter.
    pub transcript: &'a str,
    pub context: &'a DictationContext,
    /// Vocabulary terms relevant to this dictation, best first.
    pub vocabulary: &'a [String],
    /// Sound-alike matches found in the transcript.
    pub suggestions: &'a [Suggestion],
}

pub trait Cleaner: Send {
    fn name(&self) -> String;
    fn clean(&mut self, req: &CleanupRequest<'_>) -> Result<String, CleanupError>;
}

/// Words a cleanup model may introduce even though the speaker didn't say
/// them: articles, connectives and the like that fixing grammar needs.
const GLUE_WORDS: &[&str] = &[
    "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "for", "with", "is", "are", "was", "were",
    "be", "it", "that", "this", "i", "we", "you", "he", "she", "they", "s", "t", "m", "re", "ve", "ll", "d",
    "not", "do", "does", "am", "will", "would", "can", "as", "at", "by", "so", "if", "then", "also",
];

/// Check that the model only cleaned the text and didn't write new content.
///
/// The model may remove, reorder and repunctuate words, and spell vocabulary
/// terms properly. It may not add substance: too many new words, or output
/// much longer than the input, means it answered, embellished or hallucinated.
pub fn guardrail(input: &str, output: &str, vocabulary: &[String]) -> Result<(), CleanupError> {
    let output = output.trim();
    let input_words = words(input);
    let output_words = words(output);

    if output.is_empty() {
        return if input_words.len() <= 3 {
            Ok(())
        } else {
            Err(CleanupError::Rejected("empty output for a non-trivial dictation".into()))
        };
    }
    if output.chars().count() > input.chars().count() * 3 / 2 + 40 {
        return Err(CleanupError::Rejected("output much longer than the dictation".into()));
    }

    let known: HashSet<String> = input_words
        .iter()
        .cloned()
        .chain(vocabulary.iter().flat_map(|t| words(t)))
        .chain(GLUE_WORDS.iter().map(|w| w.to_string()))
        .collect();
    // Vocabulary fixes can merge spoken pieces ("kin ju" → "Kinju").
    let joined_input: String = input_words.concat();

    let novel: Vec<&String> = output_words
        .iter()
        .filter(|w| !known.contains(*w) && !w.chars().all(|c| c.is_ascii_digit()) && !joined_input.contains(w.as_str()))
        .collect();
    let allowed = 2.max(output_words.len() / 10);
    if novel.len() > allowed {
        let sample: Vec<&str> = novel.iter().take(5).map(|s| s.as_str()).collect();
        return Err(CleanupError::Rejected(format!("introduced new words: {}", sample.join(", "))));
    }
    Ok(())
}

/// Undo a model padding out a name from the vocabulary: the speaker said
/// "Priya", the model wrote "Priya Raman". Any multi-word term in the output
/// is trimmed back to the words the speaker actually said.
pub fn trim_expanded_terms(input: &str, output: &str, vocabulary: &[String]) -> String {
    let said: HashSet<String> = words(input).into_iter().collect();
    let mut out = output.to_string();
    for term in vocabulary {
        let parts: Vec<&str> = term.split_whitespace().collect();
        if parts.len() < 2 || !out.contains(term.as_str()) {
            continue;
        }
        // A respelling counts as said ("Rahman" → "Raman"); a new word doesn't.
        let was_said = |w: &String| said.contains(w) || said.iter().any(|s| strsim::jaro_winkler(s, w) >= 0.85);
        let kept: Vec<&str> = parts.iter().copied().filter(|p| words(p).iter().all(was_said)).collect();
        if !kept.is_empty() && kept.len() < parts.len() {
            out = out.replace(term.as_str(), &kept.join(" "));
        }
    }
    out
}

fn words(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| w.to_lowercase())
        .collect()
}

/// Strip wrappers small models like to add despite instructions, and the
/// <think> block some open models emit before answering.
pub(crate) fn tidy_output(raw: &str) -> String {
    let raw = match (raw.find("<think>"), raw.find("</think>")) {
        (Some(start), Some(end)) if end > start => format!("{}{}", &raw[..start], &raw[end + "</think>".len()..]),
        _ => raw.to_string(),
    };
    let mut text = raw.trim();
    for tag in ["<output>", "</output>"] {
        text = text.trim_start_matches(tag).trim_end_matches(tag).trim();
    }
    if text.len() >= 2 && text.starts_with('"') && text.ends_with('"') && text.matches('"').count() == 2 {
        text = &text[1..text.len() - 1];
    }
    text.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guardrail_accepts_repairs() {
        let input = "Send it to Sam on Friday. Actually, I actually want it to go to Priya instead.";
        assert!(guardrail(input, "Send it to Priya on Friday.", &[]).is_ok());
    }

    #[test]
    fn guardrail_accepts_vocab_merges() {
        assert!(guardrail("push the kin ju build", "Push the Kinju build.", &[]).is_ok());
        assert!(guardrail("ask siobhan", "Ask Siobhán.", &["Siobhán".into()]).is_ok());
    }

    #[test]
    fn guardrail_rejects_answers() {
        let input = "what's the capital of France";
        assert!(guardrail(input, "The capital of France is Paris, a city known for the Eiffel Tower.", &[]).is_err());
    }

    #[test]
    fn guardrail_rejects_empty_for_long_input() {
        assert!(guardrail("this is a real sentence with words", "", &[]).is_err());
        assert!(guardrail("um okay", "", &[]).is_ok());
    }

    #[test]
    fn trims_names_the_speaker_did_not_say() {
        let vocab = vec!["Priya Raman".to_string(), "Mango Tuesday".to_string()];
        assert_eq!(trim_expanded_terms("send it to priya", "Send it to Priya Raman.", &vocab), "Send it to Priya.");
        assert_eq!(trim_expanded_terms("ask priya raman", "Ask Priya Raman.", &vocab), "Ask Priya Raman.");
        assert_eq!(trim_expanded_terms("ask Priya Rahman", "Ask Priya Raman.", &vocab), "Ask Priya Raman.");
        assert_eq!(trim_expanded_terms("the mango tuesday repo", "The Mango Tuesday repo.", &vocab), "The Mango Tuesday repo.");
    }

    #[test]
    fn tidy_strips_wrappers() {
        assert_eq!(tidy_output("<output>Hi there.</output>"), "Hi there.");
        assert_eq!(tidy_output("\"Hi there.\""), "Hi there.");
        assert_eq!(tidy_output("He said \"hi\" twice"), "He said \"hi\" twice");
        assert_eq!(tidy_output("<think>hmm</think>\nHello."), "Hello.");
    }
}
