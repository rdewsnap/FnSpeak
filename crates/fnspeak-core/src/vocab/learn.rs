//! Learning from the user's own fixes. After a dictation is inserted, the
//! shell reads the field back and hands over both versions; words the user
//! respelled ("Kenju" → "Kinju") become corrections.
//!
//! A wrong correction rewrites every future dictation, so this errs hard
//! towards learning nothing: anything that looks like the user changing what
//! they meant, rather than how a word is spelled, is ignored.

use super::{normalize, word_spans};
use rphonetic::DoubleMetaphone;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::sync::OnceLock;

/// Longest phrase, in words, on either side of a correction.
const MAX_SPAN: usize = 3;
/// Beyond this the edit isn't a quick fix-up, and the diff gets expensive.
const MAX_TOKENS: usize = 400;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LearnedCorrection {
    /// What FnSpeak wrote, as lowercase words separated by single spaces.
    pub heard: String,
    /// What the user changed it to, spelled their way.
    pub corrected: String,
}

/// Find respellings between the text FnSpeak inserted and what the same
/// region of the field contains after the user edited it.
pub fn corrections_from_edit(inserted: &str, final_text: &str) -> Vec<LearnedCorrection> {
    let a_spans = word_spans(inserted);
    let b_spans = word_spans(final_text);
    if a_spans.is_empty() || a_spans.len() > MAX_TOKENS || b_spans.len() > MAX_TOKENS {
        return Vec::new();
    }
    let a: Vec<&str> = a_spans.iter().map(|&(s, e)| &inserted[s..e]).collect();
    let b: Vec<&str> = b_spans.iter().map(|&(s, e)| &final_text[s..e]).collect();

    let (kept, hunks) = diff(&a, &b);
    // Most of the dictation is gone: the user rewrote it, not respelled it.
    if a.len() >= 4 && kept * 2 < a.len() {
        return Vec::new();
    }

    let mut out: Vec<LearnedCorrection> = Vec::new();
    for h in hunks {
        let (old, new) = (h.a_end - h.a_start, h.b_end - h.b_start);
        if !(1..=MAX_SPAN).contains(&old) || !(1..=MAX_SPAN).contains(&new) {
            continue;
        }
        let heard = &inserted[a_spans[h.a_start].0..a_spans[h.a_end - 1].1];
        let start = b_spans[h.b_start].0;
        let corrected = &final_text[start..b_spans[h.b_end - 1].1];
        if !is_respelling(heard, corrected, at_sentence_start(final_text, start)) {
            continue;
        }
        let c = LearnedCorrection { heard: heard_key(heard), corrected: corrected.to_string() };
        if !out.contains(&c) {
            out.push(c);
        }
    }
    out
}

/// Replace phrases the user has corrected before. Matching is by whole
/// words, ignoring case, longest phrase first.
pub fn apply_corrections(text: &str, corrections: &[LearnedCorrection]) -> String {
    if corrections.is_empty() {
        return text.to_string();
    }
    let spans = word_spans(text);
    let lower: Vec<String> = spans.iter().map(|&(s, e)| text[s..e].to_lowercase()).collect();
    let rules: Vec<(Vec<&str>, &str)> =
        corrections.iter().map(|c| (c.heard.split(' ').collect(), c.corrected.as_str())).collect();

    let mut out = String::with_capacity(text.len());
    let (mut cursor, mut i) = (0, 0);
    while i < spans.len() {
        let rest = &lower[i..];
        let best = rules
            .iter()
            .filter(|(heard, _)| heard.len() <= rest.len() && heard.iter().zip(rest).all(|(h, w)| h == w))
            .max_by_key(|(heard, _)| heard.len());
        match best {
            Some((heard, corrected)) => {
                let (start, end) = (spans[i].0, spans[i + heard.len() - 1].1);
                out.push_str(&text[cursor..start]);
                out.push_str(corrected);
                cursor = end;
                i += heard.len();
            }
            None => i += 1,
        }
    }
    out.push_str(&text[cursor..]);
    out
}

/// The lookup key for what was heard: "Kin, ju" and "kin ju" are the same.
pub fn heard_key(text: &str) -> String {
    word_spans(text).iter().map(|&(s, e)| text[s..e].to_lowercase()).collect::<Vec<_>>().join(" ")
}

/// True when every word is an everyday English word.
pub fn is_common_phrase(text: &str) -> bool {
    let words = word_spans(text);
    !words.is_empty() && words.iter().all(|&(s, e)| common_words().contains(text[s..e].to_lowercase().as_str()))
}

/// Capitalized or mixed-case words, the way names and products are written:
/// "Kinju", "Priya Raman", "DoDSafeTransfer", "iOS".
pub fn looks_like_name(text: &str) -> bool {
    let words = word_spans(text);
    !words.is_empty()
        && words.iter().all(|&(s, e)| {
            let w = &text[s..e];
            w.chars().next().is_some_and(char::is_uppercase) || w.chars().skip(1).any(char::is_uppercase)
        })
}

fn is_respelling(heard: &str, corrected: &str, sentence_start: bool) -> bool {
    let (hn, cn) = (normalize(heard), normalize(corrected));
    if cn.chars().count() < 3 || cn.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    // Fixing a common word into another common word is grammar or a change
    // of mind ("ship" → "push", "their" → "there"), not vocabulary.
    if is_common_phrase(corrected) {
        return false;
    }

    if hn == cn {
        // Same letters: spacing or capitalization is what changed.
        if word_spans(corrected).len() < word_spans(heard).len() {
            return true; // "PG vector" → "pgvector", "kin ju" → "Kinju"
        }
        if !corrected.chars().any(char::is_uppercase) {
            return false;
        }
        // Capitalizing the first word of a sentence says nothing about the word.
        let rest_same = heard.chars().skip(1).eq(corrected.chars().skip(1));
        return !(sentence_start && rest_same);
    }

    let similarity = strsim::jaro_winkler(&hn, &cn);
    let (hl, cl) = (hn.chars().count() as f64, cn.chars().count() as f64);
    let close_length = hl.min(cl) / hl.max(cl) >= 0.75;
    let dm = DoubleMetaphone::new(None);
    let (hc, cc) = (dm.double_metaphone(&hn), dm.double_metaphone(&cn));
    let sounds_alike = [hc.primary(), hc.alternate()].iter().any(|h| !h.is_empty() && (*h == cc.primary() || *h == cc.alternate()));
    close_length && ((sounds_alike && similarity >= 0.75) || similarity >= 0.9)
}

fn at_sentence_start(text: &str, pos: usize) -> bool {
    match text[..pos].trim_end().chars().next_back() {
        None => true,
        Some(c) => matches!(c, '.' | '!' | '?' | ':' | '\n' | '"' | '“'),
    }
}

fn common_words() -> &'static HashSet<&'static str> {
    static WORDS: OnceLock<HashSet<&'static str>> = OnceLock::new();
    WORDS.get_or_init(|| include_str!("common_words.txt").split_whitespace().collect())
}

struct Hunk {
    a_start: usize,
    a_end: usize,
    b_start: usize,
    b_end: usize,
}

/// Word-level LCS diff. Returns how many words were kept and the changed runs.
fn diff(a: &[&str], b: &[&str]) -> (usize, Vec<Hunk>) {
    let (n, m) = (a.len(), b.len());
    // lcs[i][j] = longest common subsequence of a[i..] and b[j..].
    let mut lcs = vec![vec![0u16; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if a[i] == b[j] { lcs[i + 1][j + 1] + 1 } else { lcs[i + 1][j].max(lcs[i][j + 1]) };
        }
    }

    let mut hunks = Vec::new();
    let (mut i, mut j) = (0, 0);
    let mut open: Option<(usize, usize)> = None;
    let close = |open: &mut Option<(usize, usize)>, i: usize, j: usize, hunks: &mut Vec<Hunk>| {
        if let Some((a_start, b_start)) = open.take() {
            hunks.push(Hunk { a_start, a_end: i, b_start, b_end: j });
        }
    };
    while i < n || j < m {
        if i < n && j < m && a[i] == b[j] {
            close(&mut open, i, j, &mut hunks);
            i += 1;
            j += 1;
            continue;
        }
        open.get_or_insert((i, j));
        if j >= m || (i < n && lcs[i + 1][j] >= lcs[i][j + 1]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    close(&mut open, i, j, &mut hunks);
    (lcs[0][0] as usize, hunks)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn learned(inserted: &str, edited: &str) -> Vec<(String, String)> {
        corrections_from_edit(inserted, edited).into_iter().map(|c| (c.heard, c.corrected)).collect()
    }

    fn pair(heard: &str, corrected: &str) -> (String, String) {
        (heard.to_string(), corrected.to_string())
    }

    #[test]
    fn joins_a_split_name() {
        assert_eq!(learned("Push the kin ju build tonight.", "Push the Kinju build tonight."), [pair("kin ju", "Kinju")]);
    }

    #[test]
    fn respells_a_misheard_name() {
        assert_eq!(learned("Kenju is ready for review.", "Kinju is ready for review."), [pair("kenju", "Kinju")]);
        assert_eq!(learned("Ask Priya about the invoice.", "Ask Pria about the invoice."), [pair("priya", "Pria")]);
    }

    #[test]
    fn joins_lowercase_identifiers() {
        assert_eq!(learned("Review the PG vector migration.", "Review the pgvector migration."), [pair("pg vector", "pgvector")]);
    }

    #[test]
    fn learns_capitalization_mid_sentence() {
        assert_eq!(learned("I dictated this with fnspeak today.", "I dictated this with FnSpeak today."), [pair("fnspeak", "FnSpeak")]);
    }

    #[test]
    fn ignores_capitalizing_a_sentence() {
        assert!(learned("deploy is done. thanks", "Deploy is done. Thanks").is_empty());
    }

    #[test]
    fn ignores_rewrites() {
        assert!(learned(
            "We should ship the release on Friday afternoon.",
            "Let's hold the launch until the following Monday morning."
        )
        .is_empty());
        assert!(learned("Send the deck to the whole team.", "").is_empty());
    }

    #[test]
    fn ignores_common_word_swaps_and_additions() {
        assert!(learned("We should ship it today.", "We should push it today.").is_empty());
        assert!(learned("Their going to call.", "They're going to call.").is_empty());
        assert!(learned("The build is green.", "The build is green. I'll merge it after lunch with Kinju.").is_empty());
        assert!(learned("The build is green.", "The   build is green!").is_empty());
    }

    #[test]
    fn ignores_half_typed_fixes() {
        assert!(learned("Push the kin ju build.", "Push the Kin build.").is_empty());
    }

    #[test]
    fn applies_longest_match_ignoring_case() {
        let corrections = [
            LearnedCorrection { heard: "kin ju".into(), corrected: "Kinju".into() },
            LearnedCorrection { heard: "kenju".into(), corrected: "Kinju".into() },
            LearnedCorrection { heard: "pg vector".into(), corrected: "pgvector".into() },
        ];
        assert_eq!(apply_corrections("Kin ju and kenju use PG Vector.", &corrections), "Kinju and Kinju use pgvector.");
        assert_eq!(apply_corrections("kinjugate the kin", &corrections), "kinjugate the kin");
    }

    #[test]
    fn names_and_common_words() {
        assert!(looks_like_name("Priya Raman") && looks_like_name("iOS") && !looks_like_name("pgvector"));
        assert!(is_common_phrase("the build") && !is_common_phrase("the Kinju build"));
    }
}
