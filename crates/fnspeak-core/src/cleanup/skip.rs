//! Most dictations come out of the speech model and the rule-based filter
//! already clean: one or two well punctuated sentences with nothing to
//! repair. The cleanup model hands those back unchanged, and takes as long
//! as the speech model did to do it. This decides, from the text alone,
//! whether there is anything for the model to do.
//!
//! It only ever errs one way. Anything that might need judgment goes to the
//! model as before; a dictation is only kept from it when nothing in it
//! could be a filler, a correction, a list, a spoken symbol or a misheard
//! term.

use super::needs_repair;
use crate::context::Style;
use crate::vocab::{Suggestion, AUTO_APPLY_SCORE, HINT_SCORE};
use regex::Regex;
use std::sync::LazyLock;

/// Longer than this and the model may want paragraphs, and there's more
/// room for a slip the checks below don't know about.
const MAX_WORDS: usize = 40;

/// Fillers the rule-based filter leaves for the model because they're
/// sometimes real words. "like" is in "I like it" too; that just means the
/// model gets a look it didn't need.
static SOFT_FILLERS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?ix)\b(
            um+ | uh+ | erm? | hmm+ | like | you\s+know | i\s+mean | sort\s+of | kind\s+of |
            kinda | sorta | basically | literally | or\s+something | or\s+whatever | anyways?
        )\b",
    )
    .unwrap()
});

/// A word that opens a spoken sentence and usually isn't meant to be typed.
static LEAD_IN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\s*(so|well|okay|ok|yeah|yep|yes|alright|right|oh|and|but|now|look|hey)\b").unwrap());

/// Words that ask for formatting: lists, line breaks, spoken punctuation.
static FORMAT_CUES: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?ix)\b(
            new\s+line | next\s+line | new\s+paragraph | bullet | number\s+(one|two|three) |
            first(ly)? | second(ly)? | third(ly)? | colon | semicolon | comma | period | full\s+stop |
            question\s+mark | exclamation | quote | unquote | paren | parenthes[ie]s | bracket | all\s+caps | capital
        )\b",
    )
    .unwrap()
});

/// In a coding tool, words that stand for a symbol or a naming style.
static CODE_CUES: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?ix)\b(
            underscore | dot | slash | backslash | dash | hyphen | camel | snake | kebab | pascal | equals |
            backtick | brace | pipe | tilde | hash | at\s+sign | ampersand | star | asterisk | arrow | flag
        )\b",
    )
    .unwrap()
});

/// Whether the cleanup model should see this dictation. `text` is the
/// transcript after the rule-based filter.
pub fn needs_model(text: &str, style: Style, suggestions: &[Suggestion]) -> bool {
    let text = text.trim();
    // A term that sounds like something in the vocabulary, but not surely
    // enough to have been swapped in already: the model decides.
    if suggestions.iter().any(|s| s.score >= HINT_SCORE && s.score < AUTO_APPLY_SCORE) {
        return true;
    }
    if text.split_whitespace().count() > MAX_WORDS {
        return true;
    }
    if needs_repair(text) || SOFT_FILLERS.is_match(text) || LEAD_IN.is_match(text) || FORMAT_CUES.is_match(text) {
        return true;
    }
    if style == Style::Code && CODE_CUES.is_match(text) {
        return true;
    }
    !is_well_formed(text)
}

/// Starts like a sentence and ends like one, with nothing trailing off.
fn is_well_formed(text: &str) -> bool {
    let starts = text.chars().find(|c| c.is_alphanumeric()).is_some_and(|c| c.is_uppercase() || c.is_numeric());
    let ends = text.ends_with(['.', '?', '!']) && !text.ends_with("...");
    starts && ends && !text.contains("...") && !text.contains('…')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn needs(text: &str) -> bool {
        needs_model(text, Style::Prose, &[])
    }

    #[test]
    fn clean_sentences_skip_the_model() {
        assert!(!needs("Are there vehicles?"));
        assert!(!needs("I swear I was in here before."));
        assert!(!needs("The deploy went out. Staging looks fine. I'll check prod after lunch."));
        assert!(!needs("Why did all the CI tests fail? Is this what's costing us so much money on GitHub Actions?"));
        assert!(!needs_model("Run cargo test in the server crate and tell me what fails.", Style::Code, &[]));
        assert!(!needs_model("Sounds good.", Style::Casual, &[]));
    }

    #[test]
    fn anything_to_fix_goes_to_the_model() {
        // Fillers and lead-ins.
        assert!(needs("Also, like, any info we can get from him."));
        assert!(needs("I mean, the ref side is tested."));
        assert!(needs("Yeah, write up the implementation plan."));
        assert!(needs("So I think we should ship on Friday."));
        // Self-corrections.
        assert!(needs("Let's meet at 3, no wait, 4, in the big conference room."));
        assert!(needs("Send it to Sam. Actually, send it to Priya instead."));
        // Formatting.
        assert!(needs("Three things. First the demo deck. Second follow up with legal."));
        assert!(needs("Thanks for the help. New paragraph. See you Monday."));
        // Not shaped like finished text.
        assert!(needs("the tests are mostly passing"));
        assert!(needs("I built a... unofficial mod."));
        assert!(needs("Push the build to staging tonight"));
    }

    #[test]
    fn spoken_symbols_matter_only_in_code() {
        let text = "Can you rename the function to parse underscore config?";
        assert!(needs_model(text, Style::Code, &[]));
        assert!(!needs_model("Put a dash of salt in it.", Style::Prose, &[]));
    }

    #[test]
    fn an_unsure_vocabulary_match_goes_to_the_model() {
        let unsure = [Suggestion { start: 9, end: 15, heard: "kin ju".into(), term: "Kinju".into(), score: 0.8 }];
        assert!(needs_model("Push the kin ju build.", Style::Prose, &unsure));
        let applied = [Suggestion { start: 9, end: 14, heard: "Kinju".into(), term: "Kinju".into(), score: 0.99 }];
        assert!(!needs_model("Push the Kinju build.", Style::Prose, &applied));
    }

    #[test]
    fn long_dictations_go_to_the_model() {
        let long = "This sentence is perfectly fine. ".repeat(10);
        assert!(needs(&long));
    }
}
