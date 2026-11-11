//! Finding snippet triggers in dictated text and swapping in their text.

use super::Snippet;
use crate::vocab::word_spans;
use std::ops::Range;

/// A trigger found in a text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Match {
    /// Byte range of the trigger in the text.
    pub start: usize,
    pub end: usize,
    /// Index into the snippets slice given to `find`.
    pub snippet: usize,
}

/// Triggers in `text`, in order. Words are compared lowercase and whatever
/// sits between them is ignored, so "My calendar, link" matches "my
/// calendar link". The longest trigger wins where two could start at the
/// same word; of two equally long, the earlier snippet in the slice wins.
pub fn find(text: &str, snippets: &[Snippet]) -> Vec<Match> {
    let spans = word_spans(text);
    let words: Vec<String> = spans.iter().map(|&(s, e)| text[s..e].to_lowercase()).collect();
    let mut keys: Vec<(usize, Vec<&str>)> = snippets
        .iter()
        .enumerate()
        .map(|(i, s)| (i, s.trigger_key.split(' ').filter(|w| !w.is_empty()).collect::<Vec<_>>()))
        .filter(|(_, key)| !key.is_empty())
        .collect();
    // A stable sort keeps slice order among triggers of the same length.
    keys.sort_by_key(|(_, key)| std::cmp::Reverse(key.len()));

    let mut matches = Vec::new();
    let mut i = 0;
    while i < words.len() {
        let hit = keys
            .iter()
            .find(|(_, key)| i + key.len() <= words.len() && key.iter().zip(&words[i..]).all(|(k, w)| *k == w.as_str()));
        match hit {
            Some((snippet, key)) => {
                matches.push(Match { start: spans[i].0, end: spans[i + key.len() - 1].1, snippet: *snippet });
                i += key.len();
            }
            None => i += 1,
        }
    }
    matches
}

fn is_punctuation(c: char) -> bool {
    matches!(c, '.' | ',' | '!' | '?' | ';' | ':')
}

/// Replace every trigger in `text` with its snippet's text. Returns the new
/// text and the byte ranges the snippet texts occupy in it.
pub fn expand(text: &str, snippets: &[Snippet]) -> (String, Vec<Range<usize>>) {
    let mut out = String::with_capacity(text.len());
    let mut ranges = Vec::new();
    let mut cursor = 0;
    for m in find(text, snippets) {
        out.push_str(&text[cursor..m.start]);
        let body = snippets[m.snippet].text.as_str();
        let start = out.len();
        out.push_str(body);
        ranges.push(start..out.len());
        cursor = m.end;
        // Text that ends its own sentence or line shouldn't get the
        // dictation's punctuation after it: "Thanks,\nRyan\n" then ".".
        if body.chars().next_back().is_some_and(|c| c == '\n' || is_punctuation(c)) {
            if let Some(c) = text[cursor..].chars().next().filter(|c| is_punctuation(*c)) {
                cursor += c.len_utf8();
            }
        }
    }
    out.push_str(&text[cursor..]);
    (out, ranges)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::snippets::{trigger_key, SnippetSource};

    fn snip(trigger: &str, text: &str) -> Snippet {
        Snippet {
            id: trigger.into(),
            trigger: trigger.into(),
            trigger_key: trigger_key(trigger),
            text: text.into(),
            source: SnippetSource::Personal,
            team_id: None,
            team_name: None,
            can_edit: true,
            updated_at: 0,
        }
    }

    #[test]
    fn finds_a_trigger_whatever_the_case_and_punctuation() {
        let s = [snip("my calendar link", "https://cal.com/ryan")];
        let text = "Grab a time on My Calendar, link. Thanks.";
        let found = find(text, &s);
        assert_eq!(found.len(), 1);
        assert_eq!(&text[found[0].start..found[0].end], "My Calendar, link");
        assert_eq!(found[0].snippet, 0);
    }

    #[test]
    fn matches_whole_words_only() {
        let s = [snip("calendar link", "URL")];
        assert!(find("I calendar linked it", &s).is_empty());
        assert!(find("the calendar links", &s).is_empty());
        assert_eq!(find("the calendar link works", &s).len(), 1);
    }

    #[test]
    fn longest_trigger_wins_and_matches_do_not_overlap() {
        let s = [snip("calendar link", "SHORT"), snip("my work calendar link", "LONG")];
        let found = find("send my work calendar link and the calendar link", &s);
        assert_eq!(found.iter().map(|m| m.snippet).collect::<Vec<_>>(), vec![1, 0]);
    }

    #[test]
    fn expands_every_trigger_and_reports_where() {
        let s = [snip("my calendar link", "https://cal.com/ryan"), snip("office address", "1 Main St")];
        let (out, ranges) = expand("Use my calendar link or come to office address.", &s);
        assert_eq!(out, "Use https://cal.com/ryan or come to 1 Main St.");
        assert_eq!(ranges.len(), 2);
        assert_eq!(&out[ranges[0].clone()], "https://cal.com/ryan");
        assert_eq!(&out[ranges[1].clone()], "1 Main St");
    }

    #[test]
    fn drops_punctuation_after_text_that_ends_itself() {
        let s = [snip("standard closing", "Thanks,\nRyan\n"), snip("legal line", "All rights reserved.")];
        assert_eq!(expand("See you then. Standard closing.", &s).0, "See you then. Thanks,\nRyan\n");
        assert_eq!(expand("Legal line.", &s).0, "All rights reserved.");
    }

    #[test]
    fn text_without_triggers_is_untouched() {
        let s = [snip("my calendar link", "URL")];
        let (out, ranges) = expand("Nothing to see here.", &s);
        assert_eq!(out, "Nothing to see here.");
        assert!(ranges.is_empty());
        assert!(find("anything", &[]).is_empty());
    }
}
