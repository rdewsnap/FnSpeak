//! Spoken commands at the end of a dictation: "scratch that" drops the
//! last sentence, "new line" and "new paragraph" add line breaks after the
//! text, and "send it" / "send that" ask the app to press Return once the
//! text is in. Only the end of a dictation is looked at, so the same words
//! in the middle of a sentence are left alone.

/// What the commands at the end of a dictation asked for.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Trailing {
    /// Line breaks to put after the text, in the order they were said.
    pub breaks: String,
    /// "send it" was said and sending is switched on.
    pub press_enter: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Command {
    ScratchThat,
    NewLine,
    NewParagraph,
    Send,
}

/// Phrase, command, and whether it has to start its own sentence or clause
/// (after punctuation, or as the whole dictation). That keeps "add a new
/// line" or "can you send it" as text.
// Keep the phrases the same as `COMMAND_PHRASES` in fnspeak-server's snippets.rs.
const PHRASES: &[(&str, Command, bool)] = &[
    ("scratch that", Command::ScratchThat, false),
    ("new paragraph", Command::NewParagraph, true),
    ("new line", Command::NewLine, true),
    ("send it", Command::Send, true),
    ("send that", Command::Send, true),
];

/// Whether `key` (lowercase words, single spaces) is one of the spoken
/// commands. Snippet triggers can't be.
pub fn is_command_phrase(key: &str) -> bool {
    PHRASES.iter().any(|&(phrase, _, _)| phrase == key)
}

/// Take commands off the end of `text`. Returns the text to clean and
/// insert, and what the commands asked for. `send` enables "send it".
pub fn split_trailing(text: &str, send: bool) -> (String, Trailing) {
    let mut rest = text.trim_end().to_string();
    let mut breaks: Vec<&str> = Vec::new();
    let mut trailing = Trailing::default();

    while let Some((command, start)) = last_command(&rest, send && !trailing.press_enter) {
        rest.truncate(start);
        // Drop the clause punctuation that led into the command, keep a
        // sentence end: "Thanks. Send it." → "Thanks."
        let kept = rest.trim_end_matches(|c: char| c.is_whitespace() || matches!(c, ',' | ';' | ':')).len();
        rest.truncate(kept);
        match command {
            Command::ScratchThat => rest = without_last_sentence(&rest),
            Command::NewLine => breaks.push("\n"),
            Command::NewParagraph => breaks.push("\n\n"),
            Command::Send => trailing.press_enter = true,
        }
    }
    // Found back to front; said front to back.
    breaks.reverse();
    trailing.breaks = breaks.concat();
    (rest, trailing)
}

/// The command `text` ends with, and the byte offset where it starts.
fn last_command(text: &str, send: bool) -> Option<(Command, usize)> {
    let body = text.trim_end_matches(|c: char| c.is_whitespace() || matches!(c, '.' | ',' | '!' | '?' | ';' | ':'));
    for &(phrase, command, own_clause) in PHRASES {
        if command == Command::Send && !send {
            continue;
        }
        let Some(start) = body.len().checked_sub(phrase.len()) else { continue };
        if !body.is_char_boundary(start) || !body[start..].eq_ignore_ascii_case(phrase) {
            continue;
        }
        let before = &body[..start];
        // A whole word: "resend it" isn't "send it".
        if before.chars().next_back().is_some_and(|c| !c.is_whitespace() && !is_clause_end(c)) {
            continue;
        }
        let lead = before.trim_end();
        if own_clause && lead.chars().next_back().is_some_and(|c| !is_clause_end(c)) {
            continue;
        }
        return Some((command, start));
    }
    None
}

fn is_clause_end(c: char) -> bool {
    matches!(c, '.' | ',' | '!' | '?' | ';' | ':' | '\n')
}

/// Everything up to and including the end of the second-to-last sentence.
fn without_last_sentence(text: &str) -> String {
    let body = text.trim_end().trim_end_matches(['.', '!', '?']);
    match body.rfind(['.', '!', '?', '\n']) {
        Some(i) => body[..=i].trim_end().to_string(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn split(text: &str) -> (String, String, bool) {
        let (rest, t) = split_trailing(text, true);
        (rest, t.breaks, t.press_enter)
    }

    #[test]
    fn scratch_that_drops_the_last_sentence() {
        assert_eq!(split("Ship it Friday. Actually Monday works. Scratch that."), ("Ship it Friday.".into(), "".into(), false));
        assert_eq!(split("we should go scratch that"), ("".into(), "".into(), false));
        assert_eq!(split("One? Two! scratch that"), ("One?".into(), "".into(), false));
    }

    #[test]
    fn line_breaks_go_after_the_text() {
        assert_eq!(split("Dear Sam, new paragraph"), ("Dear Sam".into(), "\n\n".into(), false));
        assert_eq!(split("First item. New line."), ("First item.".into(), "\n".into(), false));
        assert_eq!(split("Hi. New line. New paragraph."), ("Hi.".into(), "\n\n\n".into(), false));
        assert_eq!(split("new paragraph"), ("".into(), "\n\n".into(), false));
    }

    #[test]
    fn send_it_presses_return() {
        assert_eq!(split("Sounds good, see you then. Send it."), ("Sounds good, see you then.".into(), "".into(), true));
        assert_eq!(split("On my way, send that"), ("On my way".into(), "".into(), true));
        assert_eq!(split("Send it"), ("".into(), "".into(), true));
        // Off unless the app turned it on.
        let (rest, t) = split_trailing("On my way. Send it.", false);
        assert_eq!((rest.as_str(), t.press_enter), ("On my way. Send it.", false));
    }

    #[test]
    fn commands_combine() {
        assert_eq!(split("Hello. Wrong bit. Scratch that. New line. Send it."), ("Hello.".into(), "\n".into(), true));
        // "scratch that" after "new line" takes the line break back.
        assert_eq!(split("Hello. New line. Scratch that."), ("Hello.".into(), "".into(), false));
    }

    #[test]
    fn leaves_the_same_words_inside_sentences() {
        assert_eq!(split("Can you send it"), ("Can you send it".into(), "".into(), false));
        assert_eq!(split("add a new line"), ("add a new line".into(), "".into(), false));
        assert_eq!(split("please resend it."), ("please resend it.".into(), "".into(), false));
        assert_eq!(split("New line characters are tricky."), ("New line characters are tricky.".into(), "".into(), false));
        assert_eq!(split("Nothing here."), ("Nothing here.".into(), "".into(), false));
    }
}
