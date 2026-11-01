//! Route by difficulty. Most dictations have no self-corrections at all, only
//! fillers and punctuation, so they can go to a cheaper, faster model. Only
//! dictations with correction cues or repeated sentences need the heavy one.

use super::{Cleaner, CleanupError, CleanupRequest};
use regex::Regex;
use std::sync::LazyLock;

static REPAIR_CUES: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?ix)\b(
            actually | no\s+wait | wait\s+no | scratch\s+that | i\s+mean | instead |
            sorry | or\s+rather | make\s+that | let\s+me\s+rephrase | correction |
            not\s+\w+[,]?\s+but | never\s*mind | delete\s+that | change\s+that\s+to
        )\b",
    )
    .unwrap()
});

/// Does this dictation need whole-utterance repair?
pub fn needs_repair(text: &str) -> bool {
    REPAIR_CUES.is_match(text) || has_repeated_sentence(text)
}

/// "The build is failing because. The build is failing because the cache…"
fn has_repeated_sentence(text: &str) -> bool {
    const LEAD_INS: &[&str] = &["so", "and", "but", "well", "okay", "ok", "um", "uh", "like"];
    let sentences: Vec<String> = text
        .split(['.', '?', '!', ','])
        .map(|s| {
            let words: Vec<String> = s.split_whitespace().map(str::to_lowercase).collect();
            let skip = words.iter().take_while(|w| LEAD_INS.contains(&w.as_str())).count();
            words[skip..].join(" ")
        })
        .filter(|s| s.split(' ').count() >= 3)
        .collect();
    sentences.windows(2).any(|pair| {
        let (a, b) = (&pair[0], &pair[1]);
        a.starts_with(b.as_str()) || b.starts_with(a.as_str()) || strsim::normalized_levenshtein(a, b) > 0.75
    })
}

/// Light model for easy dictations, heavy model for repairs.
pub struct RoutedCleaner {
    pub light: Box<dyn Cleaner>,
    pub heavy: Box<dyn Cleaner>,
}

impl Cleaner for RoutedCleaner {
    fn name(&self) -> String {
        format!("routed({} | {})", self.light.name(), self.heavy.name())
    }

    fn clean(&mut self, req: &CleanupRequest<'_>) -> Result<String, CleanupError> {
        if needs_repair(req.transcript) {
            self.heavy.clean(req)
        } else {
            self.light.clean(req)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::needs_repair;

    #[test]
    fn detects_correction_cues() {
        assert!(needs_repair("Send it to Sam. Actually, send it to Priya instead."));
        assert!(needs_repair("meet at 3, no wait, 4"));
        assert!(needs_repair("Buy milk. Scratch that."));
        assert!(needs_repair("it's not Tuesday, but Wednesday"));
    }

    #[test]
    fn detects_repeated_sentences() {
        assert!(needs_repair("So the build is failing because, the build is failing because the cache key is wrong"));
    }

    #[test]
    fn easy_dictations_stay_light() {
        assert!(!needs_repair("um so I think we should ship on Friday"));
        assert!(!needs_repair("Thanks for the update, looks good to me."));
        assert!(!needs_repair("The tests pass. The build is green. The deploy is done."));
    }
}
