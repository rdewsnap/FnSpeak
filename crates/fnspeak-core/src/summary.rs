//! Meeting summaries and note titles from the configured cleanup model.
//!
//! A transcript that doesn't fit the model's context is summarized in parts
//! and the partial summaries are merged (map, then reduce), which keeps a
//! 4k-context local model usable for an hour-long meeting.

use crate::cleanup::{CleanupError, Llm};
use crate::notes::{transcript_markdown, ActionItem, Meeting, NotesStore, Segment, SPEAKER_ME};
use regex::Regex;
use std::fmt::Write;
use std::sync::{LazyLock, Mutex};

pub const SUMMARY_PROMPT: &str = include_str!("../../../prompts/meeting_summary.md");
pub const NOTE_TITLE_PROMPT: &str = include_str!("../../../prompts/note_title.md");

/// Stored instead of a summary in filter-only and raw modes.
pub const NO_MODEL_SUMMARY: &str = "_Summaries need a cleanup model. Switch to Local or Cloud mode to summarize this meeting._";
/// Stored instead of a summary when the local model is one trained only for
/// cleanup and there's no general model to write the summary with.
pub const NEEDS_GENERAL_MODEL_SUMMARY: &str = "_Summaries need the general model. Download it, then summarize this meeting again._";
const EMPTY_SUMMARY: &str = "_Nothing was transcribed in this meeting._";

/// A rough, deliberately low estimate so chunks err on the small side.
const CHARS_PER_TOKEN: usize = 3;
/// Room for the message wrapper and tokenizer surprises.
const MARGIN_TOKENS: usize = 256;
const MAX_VOCAB_IN_PROMPT: usize = 40;
/// The pad rides along with every part of a long transcript, so it's kept
/// to what a 4k context can spare.
const MAX_NOTES_CHARS: usize = 1500;
/// Merging partial summaries can't recurse forever on a tiny context.
const MAX_REDUCE_ROUNDS: usize = 4;

#[derive(Debug, thiserror::Error)]
pub enum SummaryError {
    #[error("notes database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error(transparent)]
    Model(#[from] CleanupError),
}

/// Summarize a finished meeting and store the result. Without a model, the
/// meeting is marked done with a note saying summaries need one. The store
/// is only locked around reads and writes, never during model calls.
pub fn summarize_meeting(store: &Mutex<NotesStore>, llm: Option<&dyn Llm>, vocabulary: &[String], id: i64) -> Result<Meeting, SummaryError> {
    summarize_meeting_or(store, llm, vocabulary, id, NO_MODEL_SUMMARY)
}

/// As `summarize_meeting`, with what to store when there's no model to ask.
pub fn summarize_meeting_or(store: &Mutex<NotesStore>, llm: Option<&dyn Llm>, vocabulary: &[String], id: i64, without_model: &str) -> Result<Meeting, SummaryError> {
    let lock = || store.lock().unwrap_or_else(|e| e.into_inner());
    let (meeting, segments) = lock().meeting(id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)?;
    if meeting.raw_transcript_md.is_none() {
        lock().finish_meeting(id)?;
    }

    let summary = if segments.iter().all(|s| s.text.trim().is_empty()) {
        EMPTY_SUMMARY.to_string()
    } else {
        match llm {
            Some(llm) => summarize(llm, &meeting, &segments, vocabulary)?,
            None => without_model.to_string(),
        }
    };
    Ok(lock().set_summary(id, &summary, &parse_action_items(&summary))?)
}

/// Write the summary Markdown for a meeting.
pub fn summarize(llm: &dyn Llm, meeting: &Meeting, segments: &[Segment], vocabulary: &[String]) -> Result<String, CleanupError> {
    let header = meeting_header(meeting, segments, vocabulary);
    let max_output = (llm.context_tokens() / 4).clamp(512, 2048);
    let overhead = (SUMMARY_PROMPT.len() + header.len()) / CHARS_PER_TOKEN + MARGIN_TOKENS;
    let budget_chars = llm.context_tokens().saturating_sub(max_output + overhead).max(256) * CHARS_PER_TOKEN;

    let transcript = transcript_markdown(segments);
    let chunks = pack(transcript.lines(), budget_chars);
    let complete = |user: String| llm.complete(SUMMARY_PROMPT, &user, max_output as u32);

    if chunks.len() == 1 {
        return complete(format!("{header}<transcript>\n{}</transcript>", chunks[0]));
    }
    let mut partials = Vec::with_capacity(chunks.len());
    for (i, chunk) in chunks.iter().enumerate() {
        partials.push(complete(format!("{header}<transcript part=\"{} of {}\">\n{chunk}</transcript>", i + 1, chunks.len()))?);
    }

    for _ in 0..MAX_REDUCE_ROUNDS {
        let groups = pack_partials(&partials, budget_chars);
        let mut merged = Vec::with_capacity(groups.len());
        for group in &groups {
            merged.push(complete(format!("{header}<partial_summaries>\n{group}</partial_summaries>"))?);
        }
        if merged.len() == 1 {
            return Ok(merged.remove(0));
        }
        // No progress means each part alone fills the context; merging
        // again would loop.
        if merged.len() >= partials.len() {
            return Ok(merged.join("\n\n"));
        }
        partials = merged;
    }
    Ok(partials.join("\n\n"))
}

fn meeting_header(meeting: &Meeting, segments: &[Segment], vocabulary: &[String]) -> String {
    let mut out = String::from("<meeting>\n");
    if !meeting.title.trim().is_empty() {
        let _ = writeln!(out, "Title: {}", meeting.title.trim());
    }
    if !meeting.participants.is_empty() {
        let _ = writeln!(out, "Participants: {}", meeting.participants.join(", "));
    }
    if segments.iter().any(|s| s.speaker == SPEAKER_ME && !s.text.trim().is_empty()) {
        out.push_str("Perspective: the user took part; write as \"we\".\n");
    } else {
        out.push_str("Perspective: the user only listened; write in the third person.\n");
    }
    out.push_str("</meeting>\n");
    if let Some(notes) = meeting.notes_md.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
        let mut end = notes.len().min(MAX_NOTES_CHARS);
        while !notes.is_char_boundary(end) {
            end -= 1;
        }
        let _ = writeln!(out, "<my_notes>\n{}\n</my_notes>", &notes[..end]);
    }
    if !vocabulary.is_empty() {
        let terms: Vec<&str> = vocabulary.iter().take(MAX_VOCAB_IN_PROMPT).map(String::as_str).collect();
        let _ = writeln!(out, "<vocabulary>{}</vocabulary>", terms.join(", "));
    }
    out
}

/// Group lines into chunks of at most `budget` chars, never splitting a line
/// unless it alone is over budget.
fn pack<'a>(lines: impl Iterator<Item = &'a str>, budget: usize) -> Vec<String> {
    let mut chunks = vec![String::new()];
    for line in lines {
        let mut line = line;
        while line.len() > budget {
            let mut cut = budget;
            while !line.is_char_boundary(cut) {
                cut -= 1;
            }
            chunks.push(format!("{}\n", &line[..cut]));
            line = &line[cut..];
        }
        let current = chunks.last_mut().expect("never empty");
        if !current.is_empty() && current.len() + line.len() + 1 > budget {
            chunks.push(String::new());
        }
        let current = chunks.last_mut().expect("never empty");
        current.push_str(line);
        current.push('\n');
    }
    chunks.retain(|c| !c.is_empty());
    if chunks.is_empty() {
        chunks.push(String::new());
    }
    chunks
}

fn pack_partials(partials: &[String], budget: usize) -> Vec<String> {
    let mut groups: Vec<String> = Vec::new();
    let mut n = 0;
    for partial in partials {
        n += 1;
        let part = format!("<part n=\"{n}\">\n{}\n</part>\n", partial.trim());
        match groups.last_mut() {
            Some(g) if g.len() + part.len() <= budget => g.push_str(&part),
            _ => groups.push(part),
        }
    }
    groups
}

static DUE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*\(([^()]+)\)\s*\.?$").unwrap());
static CHECKBOX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\s*[-*+]\s*(?:\[([ xX])\]\s*)?").unwrap());

/// Pull the action items out of a summary's "Action items" section.
pub fn parse_action_items(summary_md: &str) -> Vec<ActionItem> {
    let mut items = Vec::new();
    let mut in_section = false;
    for line in summary_md.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('#') {
            in_section = trimmed.trim_start_matches('#').trim().to_lowercase().starts_with("action item");
            continue;
        }
        if !in_section {
            continue;
        }
        let Some(m) = CHECKBOX.captures(line) else {
            continue;
        };
        let done = m.get(1).is_some_and(|c| c.as_str().eq_ignore_ascii_case("x"));
        let mut rest = line[m.get(0).map_or(0, |g| g.end())..].trim().to_string();
        if rest.is_empty() || rest.trim_end_matches('.').eq_ignore_ascii_case("none") {
            continue;
        }

        let due = DUE.captures(&rest).map(|c| (c.get(0).map_or(0, |g| g.start()), c[1].trim().to_string()));
        let due = due.map(|(start, due)| {
            rest.truncate(start);
            due
        });
        let (owner, task) = match rest.split_once(':') {
            // "Priya: …" or "Me and Sam: …", but not a task with a colon in it.
            Some((owner, task)) if looks_like_names(owner) && !task.trim().is_empty() => {
                (Some(owner.trim().to_string()), task.trim().to_string())
            }
            _ => (None, rest.trim().to_string()),
        };
        items.push(ActionItem { owner, task, due, done });
    }
    items
}

fn looks_like_names(text: &str) -> bool {
    let words: Vec<&str> = text.split_whitespace().collect();
    (1..=4).contains(&words.len())
        && words.iter().all(|w| matches!(*w, "and" | "&" | "or") || w.chars().next().is_some_and(char::is_uppercase))
}

/// Title a quick note in six words or fewer. Falls back to the note's first
/// words when the model fails or returns something unusable.
pub fn title_note(llm: Option<&dyn Llm>, body: &str) -> String {
    let fallback = || fallback_title(body);
    let Some(llm) = llm else {
        return fallback();
    };
    if body.trim().is_empty() {
        return String::new();
    }
    let body: String = body.chars().take(4000).collect();
    match llm.complete(NOTE_TITLE_PROMPT, &format!("<note>{}</note>", body.trim()), 32) {
        Ok(title) => {
            let title = title.lines().find(|l| !l.trim().is_empty()).unwrap_or_default();
            let title = title.trim().trim_start_matches("Title:").trim().trim_matches(['"', '\'', '*', '#', ' ']).trim_end_matches('.');
            if title.is_empty() || title.split_whitespace().count() > 8 {
                fallback()
            } else {
                title.to_string()
            }
        }
        Err(_) => fallback(),
    }
}

/// The first six words of the first non-empty line, without Markdown marks.
pub fn fallback_title(body: &str) -> String {
    let line = body.lines().map(|l| l.trim().trim_start_matches(['#', '-', '*', '>', ' '])).find(|l| !l.is_empty()).unwrap_or_default();
    let words: Vec<&str> = line.split_whitespace().take(6).collect();
    let title = words.join(" ");
    title.trim_end_matches(['.', ',', ':', ';']).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notes::SPEAKER_OTHERS;

    /// Records prompts; answers each with a canned summary naming the call.
    struct Fake {
        context: usize,
        calls: Mutex<Vec<String>>,
    }

    impl Fake {
        fn new(context: usize) -> Self {
            Fake { context, calls: Mutex::new(vec![]) }
        }
        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
    }

    impl Llm for Fake {
        fn name(&self) -> String {
            "fake".into()
        }
        fn context_tokens(&self) -> usize {
            self.context
        }
        fn complete(&self, system: &str, user: &str, _max_tokens: u32) -> Result<String, CleanupError> {
            let mut calls = self.calls.lock().unwrap();
            calls.push(user.to_string());
            if system == NOTE_TITLE_PROMPT {
                return Ok("\"Move dentist appointment.\"".into());
            }
            Ok(format!("## Summary\n- Call {}\n\n## Action items\n- [ ] Priya: Draft release notes (Thursday)\n", calls.len()))
        }
    }

    fn store_with_meeting(lines: usize) -> (Mutex<NotesStore>, i64) {
        let store = NotesStore::in_memory().unwrap();
        let m = store.start_meeting("Launch sync", None, &["Priya".into()]).unwrap();
        for i in 0..lines {
            let speaker = if i % 2 == 0 { SPEAKER_ME } else { SPEAKER_OTHERS };
            let text = format!("Line {i} about the launch plan and who is writing which part of the release notes.");
            store.append_segment(m.id, i as i64 * 5_000, i as i64 * 5_000 + 4_000, speaker, &text, &text).unwrap();
        }
        store.finish_meeting(m.id).unwrap();
        (Mutex::new(store), m.id)
    }

    #[test]
    fn short_meeting_is_one_call() {
        let (store, id) = store_with_meeting(10);
        let llm = Fake::new(200_000);
        let m = summarize_meeting(&store, Some(&llm), &["Kinju".into()], id).unwrap();
        let calls = llm.calls();
        assert_eq!(calls.len(), 1);
        assert!(calls[0].contains("Participants: Priya"));
        assert!(calls[0].contains("write as \"we\""));
        assert!(calls[0].contains("<vocabulary>Kinju</vocabulary>"));
        assert!(calls[0].contains("[00:00:05] Others: Line 1"));
        assert_eq!(m.status, crate::notes::MeetingStatus::Done);
        assert_eq!(m.action_items[0].owner.as_deref(), Some("Priya"));
    }

    #[test]
    fn long_meeting_maps_then_reduces() {
        let (store, id) = store_with_meeting(400);
        let llm = Fake::new(4096);
        let m = summarize_meeting(&store, Some(&llm), &[], id).unwrap();
        let calls = llm.calls();
        let maps = calls.iter().filter(|c| c.contains("<transcript part=")).count();
        assert!(maps >= 3, "{maps} map calls");
        assert!(calls.last().unwrap().contains("<partial_summaries>"));
        // Every transcript line went to exactly one map call.
        for i in [0, 199, 399] {
            assert_eq!(calls.iter().filter(|c| c.contains(&format!("Line {i} about"))).count(), 1);
        }
        for c in &calls {
            assert!(c.len() / CHARS_PER_TOKEN < 4096, "prompt too big: {} chars", c.len());
        }
        assert_eq!(m.summary_md.unwrap(), format!("## Summary\n- Call {}\n\n## Action items\n- [ ] Priya: Draft release notes (Thursday)\n", calls.len()));
    }

    #[test]
    fn the_pad_goes_to_the_model_with_every_part() {
        let (store, id) = store_with_meeting(400);
        store.lock().unwrap().set_meeting_notes(id, "Ship date moved to the 14th. Ask Priya about pricing.").unwrap();
        let llm = Fake::new(4096);
        summarize_meeting(&store, Some(&llm), &[], id).unwrap();
        let calls = llm.calls();
        assert!(calls.len() > 2);
        for c in &calls {
            assert!(c.contains("<my_notes>\nShip date moved to the 14th. Ask Priya about pricing.\n</my_notes>"), "{c}");
            assert!(c.len() / CHARS_PER_TOKEN < 4096, "prompt too big: {} chars", c.len());
        }
        // Clearing the pad takes it back out.
        store.lock().unwrap().set_meeting_notes(id, "  ").unwrap();
        assert_eq!(store.lock().unwrap().meeting(id).unwrap().unwrap().0.notes_md, None);
    }

    #[test]
    fn without_a_model_the_transcript_is_kept() {
        let (store, id) = store_with_meeting(3);
        let m = summarize_meeting(&store, None, &[], id).unwrap();
        assert_eq!(m.summary_md.as_deref(), Some(NO_MODEL_SUMMARY));
        assert!(m.raw_transcript_md.unwrap().contains("Line 2"));
        assert!(m.action_items.is_empty());
    }

    #[test]
    fn empty_meeting_skips_the_model() {
        let (store, id) = store_with_meeting(0);
        let llm = Fake::new(4096);
        summarize_meeting(&store, Some(&llm), &[], id).unwrap();
        assert!(llm.calls().is_empty());
    }

    #[test]
    fn parses_action_items() {
        let md = "## Summary\n- [ ] Not an action item\n\n## Action items\n\
                  - [ ] Priya: Draft the release notes (Thursday)\n\
                  - [x] Me and Sam: Book the room\n\
                  - [ ] Find out about legal sign-off\n\
                  - [ ] Update the docs: setup and FAQ sections, plus the changelog for this release\n\
                  * Check the budget (end of month).\n\n## Open questions\n- None\n";
        let items = parse_action_items(md);
        let expect = |owner: Option<&str>, task: &str, due: Option<&str>, done: bool| ActionItem {
            owner: owner.map(String::from),
            task: task.into(),
            due: due.map(String::from),
            done,
        };
        assert_eq!(
            items,
            vec![
                expect(Some("Priya"), "Draft the release notes", Some("Thursday"), false),
                expect(Some("Me and Sam"), "Book the room", None, true),
                expect(None, "Find out about legal sign-off", None, false),
                expect(None, "Update the docs: setup and FAQ sections, plus the changelog for this release", None, false),
                expect(None, "Check the budget", Some("end of month"), false),
            ]
        );
        assert!(parse_action_items("## Action items\n- None\n").is_empty());
    }

    #[test]
    fn titles_notes() {
        let llm = Fake::new(4096);
        assert_eq!(title_note(Some(&llm), "call the dentist"), "Move dentist appointment");
        assert_eq!(title_note(None, "# call the dentist to move thursday's appointment, please."), "call the dentist to move thursday's");
        assert_eq!(fallback_title("\n\n- buy milk."), "buy milk");

        struct Broken;
        impl Llm for Broken {
            fn name(&self) -> String {
                "broken".into()
            }
            fn context_tokens(&self) -> usize {
                0
            }
            fn complete(&self, _: &str, _: &str, _: u32) -> Result<String, CleanupError> {
                Err(CleanupError::Request("offline".into()))
            }
        }
        assert_eq!(title_note(Some(&Broken), "ship it"), "ship it");
    }
}
