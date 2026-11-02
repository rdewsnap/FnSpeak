//! Quick notes and meeting transcripts, in SQLite next to the dictation
//! history. Notes, meeting titles and summaries, and transcript segments are
//! all indexed with FTS5 so one search box finds any of them.

use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub use rusqlite::Result;

/// Speaker label for audio from the user's microphone.
pub const SPEAKER_ME: &str = "me";
/// Speaker label for audio the computer played: everyone else on the call.
pub const SPEAKER_OTHERS: &str = "others";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NoteSource {
    /// Typed or dictated into the floating note bar.
    Quick,
    /// Jotted down during a meeting.
    Meeting,
    /// Saved from a regular dictation.
    Dictation,
}

impl NoteSource {
    pub fn as_str(self) -> &'static str {
        match self {
            NoteSource::Quick => "quick",
            NoteSource::Meeting => "meeting",
            NoteSource::Dictation => "dictation",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s {
            "meeting" => NoteSource::Meeting,
            "dictation" => NoteSource::Dictation,
            _ => NoteSource::Quick,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MeetingStatus {
    Recording,
    /// Recording stopped; the summary isn't written yet.
    Processing,
    Done,
}

impl MeetingStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            MeetingStatus::Recording => "recording",
            MeetingStatus::Processing => "processing",
            MeetingStatus::Done => "done",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s {
            "recording" => MeetingStatus::Recording,
            "processing" => MeetingStatus::Processing,
            _ => MeetingStatus::Done,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Note {
    pub id: i64,
    pub created_at: i64,
    pub updated_at: i64,
    pub title: String,
    pub body_md: String,
    pub source: NoteSource,
    pub meeting_id: Option<i64>,
    pub tags: Vec<String>,
    pub pinned: bool,
}

/// The editable part of a note.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct NoteDraft {
    pub title: String,
    pub body_md: String,
    pub source: NoteSource,
    pub meeting_id: Option<i64>,
    pub tags: Vec<String>,
    pub pinned: bool,
}

impl Default for NoteDraft {
    fn default() -> Self {
        NoteDraft { title: String::new(), body_md: String::new(), source: NoteSource::Quick, meeting_id: None, tags: vec![], pinned: false }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionItem {
    /// Only set when the transcript says who.
    pub owner: Option<String>,
    pub task: String,
    /// Only set when the transcript says when, in the words used.
    pub due: Option<String>,
    #[serde(default)]
    pub done: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Meeting {
    pub id: i64,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub title: String,
    pub calendar_event_id: Option<String>,
    pub participants: Vec<String>,
    pub status: MeetingStatus,
    pub summary_md: Option<String>,
    pub action_items: Vec<ActionItem>,
    /// The timestamped transcript as Markdown, frozen when recording stops.
    pub raw_transcript_md: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    pub id: i64,
    pub meeting_id: i64,
    /// Offsets from the start of the meeting.
    pub started_ms: i64,
    pub ended_ms: i64,
    /// [`SPEAKER_ME`], [`SPEAKER_OTHERS`], or a name.
    pub speaker: String,
    /// Exactly what the speech engine heard.
    pub raw: String,
    /// After the filler filter and vocabulary fixes. Never rewritten by a model.
    pub text: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HitKind {
    Note,
    Meeting,
    Segment,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SearchHit {
    pub kind: HitKind,
    pub note_id: Option<i64>,
    /// Set for meeting and segment hits.
    pub meeting_id: Option<i64>,
    pub segment_id: Option<i64>,
    /// The note's or meeting's title.
    pub title: String,
    /// Matching text with matched terms wrapped in `**`.
    pub snippet: String,
    /// When the note was last edited or the meeting started.
    pub at: i64,
    /// Where in the meeting a segment hit was said.
    pub started_ms: Option<i64>,
    /// BM25 score; lower is better.
    pub rank: f64,
}

pub struct NotesStore {
    conn: Connection,
}

const NOTE_COLUMNS: &str = "id, created_at, updated_at, title, body_md, source, meeting_id, tags_json, pinned";
const MEETING_COLUMNS: &str =
    "id, started_at, ended_at, title, calendar_event_id, participants_json, status, summary_md, action_items_json, raw_transcript_md";
const SEGMENT_COLUMNS: &str = "id, meeting_id, started_ms, ended_ms, speaker, raw, text";

impl NotesStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA foreign_keys = ON;

             CREATE TABLE IF NOT EXISTS meetings (
                 id                INTEGER PRIMARY KEY,
                 started_at        INTEGER NOT NULL,
                 ended_at          INTEGER,
                 title             TEXT NOT NULL,
                 calendar_event_id TEXT,
                 participants_json TEXT NOT NULL DEFAULT '[]',
                 status            TEXT NOT NULL CHECK (status IN ('recording', 'processing', 'done')),
                 summary_md        TEXT,
                 action_items_json TEXT,
                 raw_transcript_md TEXT
             );
             CREATE INDEX IF NOT EXISTS meetings_started ON meetings (started_at);

             CREATE TABLE IF NOT EXISTS segments (
                 id         INTEGER PRIMARY KEY,
                 meeting_id INTEGER NOT NULL REFERENCES meetings (id) ON DELETE CASCADE,
                 started_ms INTEGER NOT NULL,
                 ended_ms   INTEGER NOT NULL,
                 speaker    TEXT NOT NULL,
                 raw        TEXT NOT NULL,
                 text       TEXT NOT NULL
             );
             CREATE INDEX IF NOT EXISTS segments_meeting ON segments (meeting_id, started_ms);

             CREATE TABLE IF NOT EXISTS notes (
                 id         INTEGER PRIMARY KEY,
                 created_at INTEGER NOT NULL,
                 updated_at INTEGER NOT NULL,
                 title      TEXT NOT NULL,
                 body_md    TEXT NOT NULL,
                 source     TEXT NOT NULL CHECK (source IN ('quick', 'meeting', 'dictation')),
                 -- A note outlives the meeting it was taken in.
                 meeting_id INTEGER REFERENCES meetings (id) ON DELETE SET NULL,
                 tags_json  TEXT NOT NULL DEFAULT '[]',
                 pinned     INTEGER NOT NULL DEFAULT 0
             );
             CREATE INDEX IF NOT EXISTS notes_updated ON notes (updated_at);

             -- External-content FTS tables, kept in sync by the triggers below.
             CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                 title, body_md, content = 'notes', content_rowid = 'id', tokenize = 'porter unicode61 remove_diacritics 2'
             );
             CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(
                 title, summary_md, content = 'meetings', content_rowid = 'id', tokenize = 'porter unicode61 remove_diacritics 2'
             );
             CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
                 text, content = 'segments', content_rowid = 'id', tokenize = 'porter unicode61 remove_diacritics 2'
             );

             CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
                 INSERT INTO notes_fts (rowid, title, body_md) VALUES (new.id, new.title, new.body_md);
             END;
             CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
                 INSERT INTO notes_fts (notes_fts, rowid, title, body_md) VALUES ('delete', old.id, old.title, old.body_md);
             END;
             CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE OF title, body_md ON notes BEGIN
                 INSERT INTO notes_fts (notes_fts, rowid, title, body_md) VALUES ('delete', old.id, old.title, old.body_md);
                 INSERT INTO notes_fts (rowid, title, body_md) VALUES (new.id, new.title, new.body_md);
             END;

             CREATE TRIGGER IF NOT EXISTS meetings_ai AFTER INSERT ON meetings BEGIN
                 INSERT INTO meetings_fts (rowid, title, summary_md) VALUES (new.id, new.title, new.summary_md);
             END;
             CREATE TRIGGER IF NOT EXISTS meetings_ad AFTER DELETE ON meetings BEGIN
                 INSERT INTO meetings_fts (meetings_fts, rowid, title, summary_md) VALUES ('delete', old.id, old.title, old.summary_md);
             END;
             CREATE TRIGGER IF NOT EXISTS meetings_au AFTER UPDATE OF title, summary_md ON meetings BEGIN
                 INSERT INTO meetings_fts (meetings_fts, rowid, title, summary_md) VALUES ('delete', old.id, old.title, old.summary_md);
                 INSERT INTO meetings_fts (rowid, title, summary_md) VALUES (new.id, new.title, new.summary_md);
             END;

             CREATE TRIGGER IF NOT EXISTS segments_ai AFTER INSERT ON segments BEGIN
                 INSERT INTO segments_fts (rowid, text) VALUES (new.id, new.text);
             END;
             CREATE TRIGGER IF NOT EXISTS segments_ad AFTER DELETE ON segments BEGIN
                 INSERT INTO segments_fts (segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
             END;
             CREATE TRIGGER IF NOT EXISTS segments_au AFTER UPDATE OF text ON segments BEGIN
                 INSERT INTO segments_fts (segments_fts, rowid, text) VALUES ('delete', old.id, old.text);
                 INSERT INTO segments_fts (rowid, text) VALUES (new.id, new.text);
             END;",
        )?;
        Ok(NotesStore { conn })
    }

    // Notes

    pub fn create_note(&self, draft: &NoteDraft) -> Result<Note> {
        let now = now();
        self.conn.execute(
            "INSERT INTO notes (created_at, updated_at, title, body_md, source, meeting_id, tags_json, pinned)
             VALUES (?1, ?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![now, draft.title, draft.body_md, draft.source.as_str(), draft.meeting_id, to_json(&draft.tags), draft.pinned],
        )?;
        self.note(self.conn.last_insert_rowid())?.ok_or(rusqlite::Error::QueryReturnedNoRows)
    }

    /// Replace a note's contents. Fails with `QueryReturnedNoRows` if it's gone.
    pub fn update_note(&self, id: i64, draft: &NoteDraft) -> Result<Note> {
        let changed = self.conn.execute(
            "UPDATE notes SET updated_at = ?2, title = ?3, body_md = ?4, source = ?5, meeting_id = ?6, tags_json = ?7, pinned = ?8
             WHERE id = ?1",
            params![id, now(), draft.title, draft.body_md, draft.source.as_str(), draft.meeting_id, to_json(&draft.tags), draft.pinned],
        )?;
        if changed == 0 {
            return Err(rusqlite::Error::QueryReturnedNoRows);
        }
        self.note(id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)
    }

    pub fn delete_note(&self, id: i64) -> Result<bool> {
        Ok(self.conn.execute("DELETE FROM notes WHERE id = ?1", [id])? > 0)
    }

    pub fn note(&self, id: i64) -> Result<Option<Note>> {
        self.conn.query_row(&format!("SELECT {NOTE_COLUMNS} FROM notes WHERE id = ?1"), [id], row_to_note).optional()
    }

    /// Pinned notes first, then most recently edited.
    pub fn notes(&self, limit: usize) -> Result<Vec<Note>> {
        let mut stmt =
            self.conn.prepare(&format!("SELECT {NOTE_COLUMNS} FROM notes ORDER BY pinned DESC, updated_at DESC, id DESC LIMIT ?1"))?;
        let rows = stmt.query_map([limit as i64], row_to_note)?;
        rows.collect()
    }

    // Meetings

    pub fn start_meeting(&self, title: &str, calendar_event_id: Option<&str>, participants: &[String]) -> Result<Meeting> {
        self.conn.execute(
            "INSERT INTO meetings (started_at, title, calendar_event_id, participants_json, status) VALUES (?1, ?2, ?3, ?4, 'recording')",
            params![now(), title, calendar_event_id, to_json(participants)],
        )?;
        self.meeting_row(self.conn.last_insert_rowid())?.ok_or(rusqlite::Error::QueryReturnedNoRows)
    }

    pub fn append_segment(&self, meeting_id: i64, started_ms: i64, ended_ms: i64, speaker: &str, raw: &str, text: &str) -> Result<Segment> {
        self.conn.execute(
            "INSERT INTO segments (meeting_id, started_ms, ended_ms, speaker, raw, text) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![meeting_id, started_ms, ended_ms, speaker, raw, text],
        )?;
        Ok(Segment {
            id: self.conn.last_insert_rowid(),
            meeting_id,
            started_ms,
            ended_ms,
            speaker: speaker.to_string(),
            raw: raw.to_string(),
            text: text.to_string(),
        })
    }

    /// Stop recording: set the end time, freeze the transcript, and mark the
    /// meeting as waiting for its summary.
    pub fn finish_meeting(&self, id: i64) -> Result<Meeting> {
        let transcript = transcript_markdown(&self.segments(id)?);
        let changed = self.conn.execute(
            "UPDATE meetings SET ended_at = COALESCE(ended_at, ?2), status = 'processing', raw_transcript_md = ?3 WHERE id = ?1",
            params![id, now(), transcript],
        )?;
        if changed == 0 {
            return Err(rusqlite::Error::QueryReturnedNoRows);
        }
        self.meeting_row(id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)
    }

    pub fn set_summary(&self, id: i64, summary_md: &str, action_items: &[ActionItem]) -> Result<Meeting> {
        let changed = self.conn.execute(
            "UPDATE meetings SET summary_md = ?2, action_items_json = ?3, status = 'done' WHERE id = ?1",
            params![id, summary_md, to_json(action_items)],
        )?;
        if changed == 0 {
            return Err(rusqlite::Error::QueryReturnedNoRows);
        }
        self.meeting_row(id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)
    }

    /// Meetings still marked as recording when the app starts were cut off
    /// by a crash or quit. Finish them so they can be summarized; the end
    /// time is the last thing anyone said.
    pub fn recover_interrupted(&self) -> Result<Vec<i64>> {
        let ids: Vec<i64> = {
            let mut stmt = self.conn.prepare("SELECT id FROM meetings WHERE status = 'recording'")?;
            let rows = stmt.query_map([], |r| r.get(0))?;
            rows.collect::<Result<_>>()?
        };
        for &id in &ids {
            self.conn.execute(
                "UPDATE meetings SET ended_at = started_at + COALESCE((SELECT MAX(ended_ms) FROM segments WHERE meeting_id = ?1), 0) / 1000
                 WHERE id = ?1",
                [id],
            )?;
            self.finish_meeting(id)?;
        }
        Ok(ids)
    }

    pub fn recent_meetings(&self, limit: usize) -> Result<Vec<Meeting>> {
        let mut stmt = self.conn.prepare(&format!("SELECT {MEETING_COLUMNS} FROM meetings ORDER BY started_at DESC, id DESC LIMIT ?1"))?;
        let rows = stmt.query_map([limit as i64], row_to_meeting)?;
        rows.collect()
    }

    /// A meeting and its transcript segments in order.
    pub fn meeting(&self, id: i64) -> Result<Option<(Meeting, Vec<Segment>)>> {
        match self.meeting_row(id)? {
            Some(m) => Ok(Some((m, self.segments(id)?))),
            None => Ok(None),
        }
    }

    pub fn segments(&self, meeting_id: i64) -> Result<Vec<Segment>> {
        let mut stmt =
            self.conn.prepare(&format!("SELECT {SEGMENT_COLUMNS} FROM segments WHERE meeting_id = ?1 ORDER BY started_ms, id"))?;
        let rows = stmt.query_map([meeting_id], row_to_segment)?;
        rows.collect()
    }

    /// Delete a meeting and its transcript. Notes taken in it are kept.
    pub fn delete_meeting(&self, id: i64) -> Result<bool> {
        Ok(self.conn.execute("DELETE FROM meetings WHERE id = ?1", [id])? > 0)
    }

    fn meeting_row(&self, id: i64) -> Result<Option<Meeting>> {
        self.conn.query_row(&format!("SELECT {MEETING_COLUMNS} FROM meetings WHERE id = ?1"), [id], row_to_meeting).optional()
    }

    /// The whole meeting as one Markdown document: title, date and
    /// participants, the summary with its action items, then the transcript.
    pub fn export_meeting_markdown(&self, id: i64) -> Result<String> {
        let (m, segments) = self.meeting(id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)?;
        let mut out = String::new();
        let title = if m.title.trim().is_empty() { "Meeting" } else { m.title.trim() };
        out.push_str(&format!("# {title}\n\n"));

        let mut when = local_time(m.started_at).map(|t| t.format("%A %-d %B %Y, %H:%M").to_string()).unwrap_or_default();
        if let Some(end) = m.ended_at.and_then(local_time) {
            when.push_str(&format!("–{}", end.format("%H:%M")));
        }
        // Trailing double spaces keep these as separate lines in Markdown.
        out.push_str(&format!("**Date:** {when}  \n"));
        if !m.participants.is_empty() {
            out.push_str(&format!("**Participants:** {}  \n", m.participants.join(", ")));
        }
        out.push('\n');

        let summary = m.summary_md.as_deref().unwrap_or("").trim();
        if !summary.is_empty() {
            out.push_str(summary);
            out.push_str("\n\n");
        }
        // Summaries carry their own action items section; only add one if
        // it's missing.
        let has_section = summary.lines().any(|l| l.starts_with('#') && l.trim_start_matches('#').trim().to_lowercase().starts_with("action item"));
        if !has_section && !m.action_items.is_empty() {
            out.push_str("## Action items\n");
            for item in &m.action_items {
                out.push_str(&format!("- [{}] ", if item.done { "x" } else { " " }));
                if let Some(owner) = &item.owner {
                    out.push_str(&format!("{owner}: "));
                }
                out.push_str(&item.task);
                if let Some(due) = &item.due {
                    out.push_str(&format!(" ({due})"));
                }
                out.push('\n');
            }
            out.push('\n');
        }

        out.push_str("## Transcript\n\n");
        for line in transcript_markdown(&segments).lines() {
            out.push_str(line);
            out.push_str("  \n");
        }
        Ok(out)
    }

    // Search

    /// Search notes, meeting titles and summaries, and transcripts. Every
    /// word must match; the last one may be a prefix, so results show up
    /// while the user is still typing.
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>> {
        let Some(fts) = fts_query(query) else {
            return Ok(vec![]);
        };
        let limit = limit as i64;
        let mut hits = Vec::new();

        let mut stmt = self.conn.prepare(
            "SELECT n.id, n.meeting_id, n.title, snippet(notes_fts, -1, '**', '**', '…', 16), n.updated_at, bm25(notes_fts, 4.0, 1.0)
             FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid
             WHERE notes_fts MATCH ?1 ORDER BY 6 LIMIT ?2",
        )?;
        for hit in stmt.query_map(params![fts, limit], |r| {
            Ok(SearchHit {
                kind: HitKind::Note,
                note_id: Some(r.get(0)?),
                meeting_id: r.get(1)?,
                segment_id: None,
                title: r.get(2)?,
                snippet: r.get(3)?,
                at: r.get(4)?,
                started_ms: None,
                rank: r.get(5)?,
            })
        })? {
            hits.push(hit?);
        }

        let mut stmt = self.conn.prepare(
            "SELECT m.id, m.title, snippet(meetings_fts, -1, '**', '**', '…', 16), m.started_at, bm25(meetings_fts, 4.0, 1.0)
             FROM meetings_fts JOIN meetings m ON m.id = meetings_fts.rowid
             WHERE meetings_fts MATCH ?1 ORDER BY 5 LIMIT ?2",
        )?;
        for hit in stmt.query_map(params![fts, limit], |r| {
            Ok(SearchHit {
                kind: HitKind::Meeting,
                note_id: None,
                meeting_id: Some(r.get(0)?),
                segment_id: None,
                title: r.get(1)?,
                snippet: r.get(2)?,
                at: r.get(3)?,
                started_ms: None,
                rank: r.get(4)?,
            })
        })? {
            hits.push(hit?);
        }

        let mut stmt = self.conn.prepare(
            "SELECT s.id, s.meeting_id, m.title, snippet(segments_fts, 0, '**', '**', '…', 16), m.started_at, s.started_ms, bm25(segments_fts)
             FROM segments_fts JOIN segments s ON s.id = segments_fts.rowid JOIN meetings m ON m.id = s.meeting_id
             WHERE segments_fts MATCH ?1 ORDER BY 7 LIMIT ?2",
        )?;
        for hit in stmt.query_map(params![fts, limit], |r| {
            Ok(SearchHit {
                kind: HitKind::Segment,
                note_id: None,
                meeting_id: Some(r.get(1)?),
                segment_id: Some(r.get(0)?),
                title: r.get(2)?,
                snippet: r.get(3)?,
                at: r.get(4)?,
                started_ms: Some(r.get(5)?),
                rank: r.get(6)?,
            })
        })? {
            hits.push(hit?);
        }

        hits.sort_by(|a, b| a.rank.total_cmp(&b.rank));
        hits.truncate(limit as usize);
        Ok(hits)
    }
}

/// Turn what the user typed into an FTS5 query that can't be a syntax
/// error: every word quoted, all required, the last one a prefix.
fn fts_query(input: &str) -> Option<String> {
    let words: Vec<&str> = input.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect();
    let (last, rest) = words.split_last()?;
    let mut terms: Vec<String> = rest.iter().map(|w| format!("\"{w}\"")).collect();
    terms.push(format!("\"{last}\"*"));
    Some(terms.join(" "))
}

/// `[00:12:34] Me: …` lines, one per segment.
pub fn transcript_markdown(segments: &[Segment]) -> String {
    let mut out = String::new();
    for s in segments.iter().filter(|s| !s.text.trim().is_empty()) {
        out.push_str(&format!("[{}] {}: {}\n", timestamp(s.started_ms), speaker_label(&s.speaker), s.text.trim()));
    }
    out
}

pub fn speaker_label(speaker: &str) -> &str {
    match speaker {
        SPEAKER_ME => "Me",
        SPEAKER_OTHERS => "Others",
        other => other,
    }
}

/// Offset into a meeting as `HH:MM:SS`.
pub fn timestamp(ms: i64) -> String {
    let s = ms.max(0) / 1000;
    format!("{:02}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
}

fn to_json<T: Serialize + ?Sized>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "[]".into())
}

fn from_json<T: for<'de> Deserialize<'de> + Default>(json: Option<String>) -> T {
    json.and_then(|j| serde_json::from_str(&j).ok()).unwrap_or_default()
}

fn row_to_note(r: &Row<'_>) -> Result<Note> {
    Ok(Note {
        id: r.get(0)?,
        created_at: r.get(1)?,
        updated_at: r.get(2)?,
        title: r.get(3)?,
        body_md: r.get(4)?,
        source: NoteSource::parse(&r.get::<_, String>(5)?),
        meeting_id: r.get(6)?,
        tags: from_json(r.get(7)?),
        pinned: r.get(8)?,
    })
}

fn row_to_meeting(r: &Row<'_>) -> Result<Meeting> {
    Ok(Meeting {
        id: r.get(0)?,
        started_at: r.get(1)?,
        ended_at: r.get(2)?,
        title: r.get(3)?,
        calendar_event_id: r.get(4)?,
        participants: from_json(r.get(5)?),
        status: MeetingStatus::parse(&r.get::<_, String>(6)?),
        summary_md: r.get(7)?,
        action_items: from_json(r.get(8)?),
        raw_transcript_md: r.get(9)?,
    })
}

fn row_to_segment(r: &Row<'_>) -> Result<Segment> {
    Ok(Segment {
        id: r.get(0)?,
        meeting_id: r.get(1)?,
        started_ms: r.get(2)?,
        ended_ms: r.get(3)?,
        speaker: r.get(4)?,
        raw: r.get(5)?,
        text: r.get(6)?,
    })
}

fn local_time(unix: i64) -> Option<chrono::DateTime<chrono::Local>> {
    chrono::DateTime::from_timestamp(unix, 0).map(|t| t.with_timezone(&chrono::Local))
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quick(title: &str, body: &str) -> NoteDraft {
        NoteDraft { title: title.into(), body_md: body.into(), ..Default::default() }
    }

    fn meeting_with_segments(store: &NotesStore) -> Meeting {
        let m = store.start_meeting("Kinju launch sync", Some("evt-1"), &["Priya".into(), "Sam".into()]).unwrap();
        store.append_segment(m.id, 0, 4_000, SPEAKER_ME, "um so the launch is friday", "So the launch is Friday").unwrap();
        store.append_segment(m.id, 754_000, 760_000, SPEAKER_OTHERS, "i'll draft the release notes", "I'll draft the release notes").unwrap();
        m
    }

    #[test]
    fn note_crud() {
        let store = NotesStore::in_memory().unwrap();
        let a = store.create_note(&quick("Groceries", "milk, eggs")).unwrap();
        let b = store.create_note(&NoteDraft { tags: vec!["work".into()], pinned: true, ..quick("Standup", "ship the build") }).unwrap();
        assert_eq!(b.tags, vec!["work".to_string()]);
        assert_eq!(store.notes(10).unwrap().iter().map(|n| n.id).collect::<Vec<_>>(), vec![b.id, a.id]);

        let updated = store.update_note(a.id, &quick("Groceries", "milk, eggs, bread")).unwrap();
        assert_eq!(updated.body_md, "milk, eggs, bread");
        assert_eq!(updated.created_at, a.created_at);
        assert!(store.delete_note(a.id).unwrap());
        assert!(!store.delete_note(a.id).unwrap());
        assert!(store.update_note(a.id, &quick("x", "y")).is_err());
        assert_eq!(store.notes(10).unwrap().len(), 1);
    }

    #[test]
    fn search_tracks_note_edits() {
        let store = NotesStore::in_memory().unwrap();
        let n = store.create_note(&quick("Ideas", "try pgvector for search")).unwrap();
        assert_eq!(store.search("pgvector", 10).unwrap()[0].note_id, Some(n.id));
        // Prefix matching on the last word, stemming on the rest.
        assert_eq!(store.search("pgvec", 10).unwrap().len(), 1);
        assert_eq!(store.search("searching pgvector", 10).unwrap().len(), 1);

        store.update_note(n.id, &quick("Ideas", "try sqlite for search")).unwrap();
        assert!(store.search("pgvector", 10).unwrap().is_empty());
        assert_eq!(store.search("sqlite", 10).unwrap().len(), 1);
        store.delete_note(n.id).unwrap();
        assert!(store.search("sqlite", 10).unwrap().is_empty());
    }

    #[test]
    fn search_mixes_notes_meetings_and_segments() {
        let store = NotesStore::in_memory().unwrap();
        let m = meeting_with_segments(&store);
        store.create_note(&quick("Release notes", "remember the changelog")).unwrap();

        let hits = store.search("release notes", 10).unwrap();
        let kinds: Vec<HitKind> = hits.iter().map(|h| h.kind).collect();
        assert!(kinds.contains(&HitKind::Note) && kinds.contains(&HitKind::Segment));
        let seg = hits.iter().find(|h| h.kind == HitKind::Segment).unwrap();
        assert_eq!((seg.meeting_id, seg.started_ms, seg.title.as_str()), (Some(m.id), Some(754_000), "Kinju launch sync"));
        assert!(seg.snippet.contains("**release**"));

        assert_eq!(store.search("kinju", 10).unwrap()[0].kind, HitKind::Meeting);
        assert!(store.search("  \"*(", 10).unwrap().is_empty());
    }

    #[test]
    fn meeting_lifecycle() {
        let store = NotesStore::in_memory().unwrap();
        let m = meeting_with_segments(&store);
        assert_eq!(m.status, MeetingStatus::Recording);
        assert_eq!(m.participants, vec!["Priya".to_string(), "Sam".to_string()]);

        let finished = store.finish_meeting(m.id).unwrap();
        assert_eq!(finished.status, MeetingStatus::Processing);
        assert!(finished.ended_at.is_some());
        assert_eq!(
            finished.raw_transcript_md.as_deref(),
            Some("[00:00:00] Me: So the launch is Friday\n[00:12:34] Others: I'll draft the release notes\n")
        );

        let items = vec![ActionItem { owner: Some("Others".into()), task: "Draft the release notes".into(), due: None, done: false }];
        let done = store.set_summary(m.id, "## Summary\n- Launch is Friday", &items).unwrap();
        assert_eq!((done.status, done.action_items.clone()), (MeetingStatus::Done, items));
        assert_eq!(store.search("launch", 10).unwrap().iter().filter(|h| h.kind == HitKind::Meeting).count(), 1);

        let (_, segments) = store.meeting(m.id).unwrap().unwrap();
        assert_eq!(segments.len(), 2);
        assert_eq!(store.recent_meetings(5).unwrap().len(), 1);
    }

    #[test]
    fn deleting_a_meeting_removes_its_transcript_but_keeps_notes() {
        let store = NotesStore::in_memory().unwrap();
        let m = meeting_with_segments(&store);
        let note = store.create_note(&NoteDraft { source: NoteSource::Meeting, meeting_id: Some(m.id), ..quick("Aside", "ask about budget") }).unwrap();

        assert!(store.delete_meeting(m.id).unwrap());
        assert!(store.meeting(m.id).unwrap().is_none());
        assert!(store.segments(m.id).unwrap().is_empty());
        assert!(store.search("release", 10).unwrap().is_empty());
        assert_eq!(store.note(note.id).unwrap().unwrap().meeting_id, None);
    }

    #[test]
    fn recovers_meetings_cut_off_mid_recording() {
        let store = NotesStore::in_memory().unwrap();
        let m = meeting_with_segments(&store);
        assert_eq!(store.recover_interrupted().unwrap(), vec![m.id]);
        let (m2, _) = store.meeting(m.id).unwrap().unwrap();
        assert_eq!(m2.status, MeetingStatus::Processing);
        assert_eq!(m2.ended_at, Some(m.started_at + 760));
        assert!(store.recover_interrupted().unwrap().is_empty());
    }

    #[test]
    fn exports_markdown() {
        let store = NotesStore::in_memory().unwrap();
        let m = meeting_with_segments(&store);
        store.finish_meeting(m.id).unwrap();
        let items = vec![
            ActionItem { owner: Some("Priya".into()), task: "Draft the release notes".into(), due: Some("Thursday".into()), done: false },
            ActionItem { owner: None, task: "Book the room".into(), due: None, done: true },
        ];
        store.set_summary(m.id, "## Summary\n- The launch is Friday.", &items).unwrap();

        let md = store.export_meeting_markdown(m.id).unwrap();
        assert!(md.starts_with("# Kinju launch sync\n\n**Date:** "));
        assert!(md.contains("**Participants:** Priya, Sam  \n"));
        assert!(md.contains(
            "## Summary\n- The launch is Friday.\n\n## Action items\n- [ ] Priya: Draft the release notes (Thursday)\n- [x] Book the room\n"
        ));
        assert!(md.ends_with("## Transcript\n\n[00:00:00] Me: So the launch is Friday  \n[00:12:34] Others: I'll draft the release notes  \n"));

        // A summary that already lists its action items doesn't get a second list.
        store.set_summary(m.id, "## Summary\n- Ship.\n\n## Action items\n- [ ] Priya: Draft the release notes (Thursday)", &items).unwrap();
        assert_eq!(store.export_meeting_markdown(m.id).unwrap().matches("## Action items").count(), 1);
        assert!(store.export_meeting_markdown(m.id + 1).is_err());
    }

    #[test]
    fn persists_to_disk() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("notes.db");
        let id = NotesStore::open(&path).unwrap().create_note(&quick("Keep", "this one")).unwrap().id;
        let store = NotesStore::open(&path).unwrap();
        assert_eq!(store.note(id).unwrap().unwrap().title, "Keep");
        assert_eq!(store.search("keep", 10).unwrap().len(), 1);
    }
}
