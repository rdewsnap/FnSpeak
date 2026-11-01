//! Rule-based disfluency filter.
//!
//! This is the first cleanup layer: instant, deterministic, and always on
//! (outside raw mode). It only removes things that are never meaningful in
//! dictation — "um", "uh", stutters like "I-I", and immediate repeats like
//! "the the". Anything that needs judgment ("like", "you know", false starts,
//! "actually… instead") is left for the cleanup model.
//!
//! Its output is also the fallback whenever the cleanup model is off, slow,
//! or fails, so it has to be safe on its own.

use regex::Regex;
use std::sync::LazyLock;

static FILLER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(u+m+|u+h+|u+h+m+|e+r+m*|a+h+|h+m+|m{2,})$").unwrap()
});

/// Words that are legitimately doubled in normal speech ("had had", "that that").
const ALLOWED_REPEATS: &[&str] = &[
    "had", "that", "very", "really", "so", "no", "bye", "ha", "yeah", "knock", "blah",
];

/// Run the full rule-based filter.
pub fn filter(text: &str) -> String {
    let tokens: Vec<Token> = text.split_whitespace().map(Token::new).collect();
    let tokens = remove_fillers(tokens);
    let tokens = collapse_stutters(tokens);
    let tokens = collapse_repeats(tokens);
    join(&tokens)
}

#[derive(Clone, Debug)]
struct Token {
    /// The word without trailing punctuation, as written.
    word: String,
    /// Trailing punctuation, e.g. "," or "?".
    punct: String,
}

impl Token {
    fn new(raw: &str) -> Self {
        let split = raw
            .char_indices()
            .rev()
            .take_while(|(_, c)| is_trailing_punct(*c))
            .last()
            .map(|(i, _)| i)
            .unwrap_or(raw.len());
        Token {
            word: raw[..split].to_string(),
            punct: raw[split..].to_string(),
        }
    }

    fn key(&self) -> String {
        self.word.to_lowercase()
    }

    fn ends_sentence(&self) -> bool {
        self.punct.contains(['.', '!', '?'])
    }

    fn is_filler(&self) -> bool {
        FILLER.is_match(&self.word)
    }
}

fn is_trailing_punct(c: char) -> bool {
    matches!(c, ',' | '.' | '!' | '?' | ';' | ':' | '…')
}

fn remove_fillers(tokens: Vec<Token>) -> Vec<Token> {
    let mut out: Vec<Token> = Vec::with_capacity(tokens.len());
    let mut capitalize_next = false;

    for tok in tokens {
        if tok.is_filler() {
            let at_sentence_start = out.last().is_none_or(|t| t.ends_sentence());
            if at_sentence_start {
                capitalize_next = true;
            }
            // "That's it, um." — keep the sentence end the filler was carrying.
            if tok.ends_sentence() {
                if let Some(prev) = out.last_mut() {
                    let end: String = tok.punct.chars().filter(|c| matches!(c, '.' | '!' | '?')).collect();
                    prev.punct = prev.punct.trim_end_matches([',', ';', ':']).to_string() + &end;
                }
                capitalize_next = true;
            }
            continue;
        }
        let mut tok = tok;
        if capitalize_next {
            tok.word = capitalize(&tok.word);
            capitalize_next = false;
        }
        out.push(tok);
    }
    out
}

/// "I-I think" → "I think", "th-the" → "the", "w-w-what" → "what".
fn collapse_stutters(tokens: Vec<Token>) -> Vec<Token> {
    tokens
        .into_iter()
        .map(|mut tok| {
            let parts: Vec<&str> = tok.word.split('-').collect();
            if parts.len() < 2 {
                return tok;
            }
            let last = parts[parts.len() - 1];
            let last_lower = last.to_lowercase();
            let is_stutter = parts[..parts.len() - 1].iter().all(|p| {
                let p = p.to_lowercase();
                !p.is_empty()
                    && (p == last_lower
                        || (last_lower.starts_with(&p) && !p.chars().any(is_vowel)))
            });
            if is_stutter && !last.is_empty() {
                // Keep the capitalization of the first fragment ("Th-the" → "The").
                tok.word = if parts[0].chars().next().is_some_and(char::is_uppercase) {
                    capitalize(last)
                } else {
                    last.to_string()
                };
            }
            tok
        })
        .collect()
}

/// Drop immediate repeats of 1–3 words: "the the" → "the", "I want I want" → "I want".
/// A repeat separated by punctuation ("no, no") is treated as intentional.
fn collapse_repeats(mut tokens: Vec<Token>) -> Vec<Token> {
    for n in (1..=3).rev() {
        let mut i = 0;
        while i + 2 * n <= tokens.len() {
            let first = &tokens[i..i + n];
            let second = &tokens[i + n..i + 2 * n];
            let same = first.iter().zip(second).all(|(a, b)| a.key() == b.key());
            let unbroken = first.iter().all(|t| t.punct.is_empty());
            let allowed = n == 1 && ALLOWED_REPEATS.contains(&first[0].key().as_str());
            if same && unbroken && !allowed {
                // Keep the first copy's capitalization (it may start a sentence).
                let caps: Vec<String> = first.iter().map(|t| t.word.clone()).collect();
                tokens.drain(i..i + n);
                for (t, w) in tokens[i..i + n].iter_mut().zip(caps) {
                    t.word = w;
                }
                // Re-check at the same position: "the the the".
                continue;
            }
            i += 1;
        }
    }
    tokens
}

fn join(tokens: &[Token]) -> String {
    let mut s = String::new();
    for tok in tokens {
        if !s.is_empty() {
            s.push(' ');
        }
        s.push_str(&tok.word);
        s.push_str(&tok.punct);
    }
    s
}

fn is_vowel(c: char) -> bool {
    matches!(c.to_ascii_lowercase(), 'a' | 'e' | 'i' | 'o' | 'u' | 'y')
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::filter;

    #[test]
    fn removes_plain_fillers() {
        assert_eq!(filter("so um I think uh we should go"), "so I think we should go");
        assert_eq!(filter("Ummm, hmm, yes."), "Yes.");
    }

    #[test]
    fn capitalizes_after_sentence_start_filler() {
        assert_eq!(filter("Um, so we ship Friday."), "So we ship Friday.");
        assert_eq!(filter("Done. Uh, next one."), "Done. Next one.");
    }

    #[test]
    fn keeps_sentence_end_carried_by_filler() {
        assert_eq!(filter("That's it, um. Thanks"), "That's it. Thanks");
    }

    #[test]
    fn keeps_list_commas() {
        assert_eq!(filter("apples, um, oranges"), "apples, oranges");
    }

    #[test]
    fn collapses_stutters() {
        assert_eq!(filter("I-I think th-the build is w-w-working"), "I think the build is working");
        assert_eq!(filter("Th-the end"), "The end");
    }

    #[test]
    fn leaves_real_hyphenated_words() {
        assert_eq!(filter("re-read the e-mail about the x-ray"), "re-read the e-mail about the x-ray");
    }

    #[test]
    fn collapses_repeats() {
        assert_eq!(filter("send it to the the team"), "send it to the team");
        assert_eq!(filter("I want I want the blue one"), "I want the blue one");
        assert_eq!(filter("the the the end"), "the end");
        assert_eq!(filter("The the end"), "The end");
    }

    #[test]
    fn keeps_intentional_repeats() {
        assert_eq!(filter("what he had had was enough"), "what he had had was enough");
        assert_eq!(filter("no, no, that's fine"), "no, no, that's fine");
        assert_eq!(filter("it was very very good"), "it was very very good");
    }

    #[test]
    fn keeps_words_that_only_look_like_fillers() {
        assert_eq!(filter("the umbrella and the ermine"), "the umbrella and the ermine");
        assert_eq!(filter("uh-huh, sounds good"), "uh-huh, sounds good");
    }

    #[test]
    fn empty_and_all_filler() {
        assert_eq!(filter(""), "");
        assert_eq!(filter("um uh"), "");
    }
}
