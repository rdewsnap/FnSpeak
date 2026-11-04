//! Scoring. Every metric works on plain text so transcripts from other
//! tools (other dictation apps, macOS dictation) can be scored the same way.

/// Lowercase words with punctuation stripped, for word error rate.
pub fn normalize_words(text: &str) -> Vec<String> {
    text.split(|c: char| c.is_whitespace() || matches!(c, ',' | '.' | '!' | '?' | ';' | ':' | '"' | '(' | ')'))
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase())
        .filter(|w| !w.is_empty())
        .collect()
}

/// Word-level edit distance between reference and hypothesis.
pub fn word_errors(reference: &str, hypothesis: &str) -> (usize, usize) {
    let r = normalize_words(reference);
    let h = normalize_words(hypothesis);
    let mut prev: Vec<usize> = (0..=h.len()).collect();
    for i in 1..=r.len() {
        let mut cur = vec![i; h.len() + 1];
        for j in 1..=h.len() {
            let sub = prev[j - 1] + usize::from(r[i - 1] != h[j - 1]);
            cur[j] = sub.min(prev[j] + 1).min(cur[j - 1] + 1);
        }
        prev = cur;
    }
    (prev[h.len()], r.len())
}

/// Did each expected term appear spelled exactly right (case-sensitive)?
pub fn terms_correct(hypothesis: &str, terms: &[String]) -> usize {
    terms.iter().filter(|t| contains_word(hypothesis, t)).count()
}

fn contains_word(haystack: &str, needle: &str) -> bool {
    haystack.match_indices(needle).any(|(i, _)| {
        let before = haystack[..i].chars().next_back();
        let after = haystack[i + needle.len()..].chars().next();
        !before.is_some_and(char::is_alphanumeric) && !after.is_some_and(char::is_alphanumeric)
    })
}

const FILLERS: &[&str] = &["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm"];
const FILLER_PHRASES: &[&str] = &["you know", "i mean", "sort of", "kind of"];

/// Filler words left in the text. Phrases only count when the reference
/// doesn't use them on purpose.
pub fn fillers_left(reference: &str, hypothesis: &str) -> usize {
    let words = normalize_words(hypothesis);
    let single = words.iter().filter(|w| FILLERS.contains(&w.as_str())).count();
    let joined = words.join(" ");
    let reference = normalize_words(reference).join(" ");
    let phrases: usize = FILLER_PHRASES
        .iter()
        .map(|p| joined.matches(p).count().saturating_sub(reference.matches(p).count()))
        .sum();
    single + phrases
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wer() {
        assert_eq!(word_errors("Send it to Priya.", "send it to priya"), (0, 4));
        assert_eq!(word_errors("Send it to Priya.", "send it to Sam"), (1, 4));
        assert_eq!(word_errors("a b c", ""), (3, 3));
        assert_eq!(word_errors("a b", "a x b"), (1, 2));
    }

    #[test]
    fn terms_are_case_sensitive_whole_words() {
        let terms = vec!["Kinju".to_string(), "Priya Raman".to_string()];
        assert_eq!(terms_correct("ship Kinju to Priya Raman", &terms), 2);
        assert_eq!(terms_correct("ship kinju to Priya Ramanujan", &terms), 0);
    }

    #[test]
    fn counts_fillers() {
        assert_eq!(fillers_left("ship it", "um ship it uh"), 2);
        assert_eq!(fillers_left("you know the drill", "you know the drill"), 0);
        assert_eq!(fillers_left("ship it", "you know ship it"), 1);
    }
}
