//! Read-only access to Flowstate's `notes.db` and `history.db`.
//!
//! Every call opens the databases fresh with `SQLITE_OPEN_READ_ONLY`, so the
//! app can create or migrate them at any time and a missing file simply reads
//! as "nothing here yet".

use anyhow::{bail, Context, Result};
use chrono::DateTime;
use rusqlite::{params, Connection, OpenFlags, Params, Row};
use serde::Serialize;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_LIMIT: usize = 200;

pub struct Store {
    dir: PathBuf,
    allow_write: bool,
}

#[derive(Serialize, Debug)]
pub struct Hit {
    pub kind: &'static str,
    pub id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub meeting_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_id: Option<String>,
    pub at: i64,
    pub at_iso: String,
    pub snippet: String,
}

#[derive(Serialize, Debug)]
pub struct Note {
    pub id: i64,
    pub title: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub updated_at_iso: String,
    pub source: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub meeting_id: Option<i64>,
    pub tags: Vec<String>,
    pub pinned: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body_md: Option<String>,
}

#[derive(Serialize, Debug)]
pub struct MeetingInfo {
    pub id: i64,
    pub title: String,
    pub started_at: i64,
    pub started_at_iso: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_minutes: Option<i64>,
    pub status: String,
    pub participants: Vec<String>,
    pub has_summary: bool,
}

#[derive(Serialize, Debug)]
pub struct MeetingDetail {
    #[serde(flatten)]
    pub info: MeetingInfo,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary_md: Option<String>,
    pub action_items: Vec<ActionItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcript: Option<String>,
}

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct ActionItem {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    pub done: bool,
}

#[derive(Serialize, Debug)]
pub struct MeetingActionItem {
    pub meeting_id: i64,
    pub meeting_title: String,
    pub meeting_date: String,
    #[serde(flatten)]
    pub item: ActionItem,
}

#[derive(Serialize, Debug)]
pub struct Dictation {
    pub id: i64,
    pub created_at: i64,
    pub created_at_iso: String,
    pub app_id: String,
    pub text: String,
    pub raw: String,
    pub mode: String,
}

struct MeetingRow {
    info: MeetingInfo,
    summary_md: Option<String>,
    action_items_json: Option<String>,
    raw_transcript_md: Option<String>,
}

struct Segment {
    started_ms: i64,
    speaker: String,
    text: String,
}

impl Store {
    pub fn new(dir: impl Into<PathBuf>, allow_write: bool) -> Self {
        Store { dir: dir.into(), allow_write }
    }

    pub fn notes_path(&self) -> PathBuf {
        self.dir.join("notes.db")
    }

    pub fn notes_missing(&self) -> bool {
        !self.notes_path().exists()
    }

    pub fn history_missing(&self) -> bool {
        !self.dir.join("history.db").exists()
    }

    fn notes(&self) -> Result<Option<Connection>> {
        open_ro(&self.notes_path())
    }

    fn history(&self) -> Result<Option<Connection>> {
        open_ro(&self.dir.join("history.db"))
    }

    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<Hit>> {
        let limit = clamp(limit);
        let (mut notes, mut segments, mut dictations) = (vec![], vec![], vec![]);
        if let Some(c) = self.notes()? {
            notes = tolerate_missing(search_notes(&c, query, limit))?;
            segments = tolerate_missing(search_segments(&c, query, limit))?;
        }
        if let Some(c) = self.history()? {
            dictations = tolerate_missing(search_dictations(&c, query, limit))?;
        }
        Ok(interleave(vec![notes, segments, dictations], limit))
    }

    pub fn list_notes(&self, limit: usize, pinned_only: bool) -> Result<Vec<Note>> {
        let Some(c) = self.notes()? else { return Ok(vec![]) };
        let sql = format!(
            "SELECT id, created_at, updated_at, title, body_md, source, meeting_id, tags_json, pinned FROM notes {} ORDER BY pinned DESC, updated_at DESC LIMIT ?1",
            if pinned_only { "WHERE pinned != 0" } else { "" }
        );
        let mut notes = tolerate_missing(query_all(&c, &sql, [clamp(limit) as i64], note_row))?;
        for n in &mut notes {
            n.preview = n.body_md.take().map(|b| crop(&b, &[], 200));
        }
        Ok(notes)
    }

    pub fn get_note(&self, id: i64) -> Result<Option<Note>> {
        let Some(c) = self.notes()? else { return Ok(None) };
        let notes = tolerate_missing(query_all(
            &c,
            "SELECT id, created_at, updated_at, title, body_md, source, meeting_id, tags_json, pinned FROM notes WHERE id = ?1",
            [id],
            note_row,
        ))?;
        Ok(notes.into_iter().next())
    }

    pub fn list_meetings(&self, since_unix: Option<i64>, limit: usize) -> Result<Vec<MeetingInfo>> {
        let Some(c) = self.notes()? else { return Ok(vec![]) };
        let rows = tolerate_missing(query_all(
            &c,
            &format!("{MEETING_COLS} FROM meetings WHERE started_at >= ?1 ORDER BY started_at DESC LIMIT ?2"),
            params![since_unix.unwrap_or(0), clamp(limit) as i64],
            meeting_row,
        ))?;
        Ok(rows.into_iter().map(|m| m.info).collect())
    }

    fn meeting_row(&self, c: &Connection, id: i64) -> Result<Option<MeetingRow>> {
        let rows = tolerate_missing(query_all(c, &format!("{MEETING_COLS} FROM meetings WHERE id = ?1"), [id], meeting_row))?;
        Ok(rows.into_iter().next())
    }

    pub fn get_meeting(&self, id: i64, include_transcript: bool) -> Result<Option<MeetingDetail>> {
        let Some(c) = self.notes()? else { return Ok(None) };
        let Some(row) = self.meeting_row(&c, id)? else { return Ok(None) };
        let transcript = if include_transcript { Some(transcript_text(&c, id, &row)?) } else { None };
        let action_items = parse_action_items(row.action_items_json.as_deref(), row.summary_md.as_deref());
        Ok(Some(MeetingDetail { info: row.info, summary_md: row.summary_md, action_items, transcript }))
    }

    /// `Ok(None)` when the meeting doesn't exist; `Ok(Some(None))` when it has no summary yet.
    pub fn get_meeting_summary(&self, id: i64) -> Result<Option<Option<String>>> {
        let Some(c) = self.notes()? else { return Ok(None) };
        Ok(self.meeting_row(&c, id)?.map(|m| m.summary_md.filter(|s| !s.trim().is_empty())))
    }

    pub fn list_action_items(&self, open_only: bool) -> Result<Vec<MeetingActionItem>> {
        let Some(c) = self.notes()? else { return Ok(vec![]) };
        let rows = tolerate_missing(query_all(
            &c,
            &format!("{MEETING_COLS} FROM meetings ORDER BY started_at DESC LIMIT 500"),
            [],
            meeting_row,
        ))?;
        let mut out = vec![];
        for m in rows {
            for item in parse_action_items(m.action_items_json.as_deref(), m.summary_md.as_deref()) {
                if open_only && item.done {
                    continue;
                }
                out.push(MeetingActionItem {
                    meeting_id: m.info.id,
                    meeting_title: m.info.title.clone(),
                    meeting_date: date_only(m.info.started_at),
                    item,
                });
            }
        }
        Ok(out)
    }

    pub fn recent_dictations(&self, limit: usize, app_id: Option<&str>) -> Result<Vec<Dictation>> {
        let Some(c) = self.history()? else { return Ok(vec![]) };
        tolerate_missing(query_all(
            &c,
            "SELECT id, created_at, app_id, raw, text, mode FROM dictations WHERE (?1 IS NULL OR app_id = ?1) ORDER BY id DESC LIMIT ?2",
            params![app_id, clamp(limit) as i64],
            |r| {
                let created_at: i64 = r.get(1)?;
                Ok(Dictation {
                    id: r.get(0)?,
                    created_at,
                    created_at_iso: iso(created_at),
                    app_id: text_col(r, 2)?,
                    raw: text_col(r, 3)?,
                    text: text_col(r, 4)?,
                    mode: text_col(r, 5)?,
                })
            },
        ))
    }

    pub fn export_meeting_markdown(&self, id: i64) -> Result<Option<String>> {
        let Some(c) = self.notes()? else { return Ok(None) };
        let Some(row) = self.meeting_row(&c, id)? else { return Ok(None) };
        let info = &row.info;
        let mut md = format!("# {}\n\n**Date:** {}", info.title, minute_stamp(info.started_at));
        if let Some(mins) = info.duration_minutes {
            md.push_str(&format!(" ({mins} min)"));
        }
        md.push('\n');
        if !info.participants.is_empty() {
            md.push_str(&format!("**Participants:** {}\n", info.participants.join(", ")));
        }
        if let Some(summary) = row.summary_md.as_deref().filter(|s| !s.trim().is_empty()) {
            md.push_str(&format!("\n## Summary\n\n{}\n", summary.trim()));
        }
        let items = parse_action_items(row.action_items_json.as_deref(), row.summary_md.as_deref());
        if !items.is_empty() {
            md.push_str("\n## Action items\n\n");
            for i in &items {
                let owner = i.owner.as_deref().map(|o| format!(" ({o})")).unwrap_or_default();
                md.push_str(&format!("- [{}] {}{}\n", if i.done { "x" } else { " " }, i.text, owner));
            }
        }
        let transcript = transcript_text(&c, id, &row)?;
        if !transcript.trim().is_empty() {
            md.push_str(&format!("\n## Transcript\n\n{}\n", transcript.trim_end()));
        }
        Ok(Some(md))
    }

    pub fn note_markdown(&self, id: i64) -> Result<Option<String>> {
        Ok(self.get_note(id)?.map(|n| format!("# {}\n\n{}\n", n.title, n.body_md.unwrap_or_default().trim_end())))
    }

    pub fn create_note(&self, title: &str, body: &str) -> Result<i64> {
        if !self.allow_write {
            bail!("writing is disabled; start flowstate-mcp with --allow-write");
        }
        let path = self.notes_path();
        if !path.exists() {
            bail!("{} doesn't exist yet; open Flowstate once so it can create it", path.display());
        }
        let c = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX)
            .with_context(|| format!("opening {}", path.display()))?;
        c.busy_timeout(Duration::from_secs(5))?;
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() as i64;
        c.execute(
            "INSERT INTO notes (created_at, updated_at, title, body_md, source, meeting_id, tags_json, pinned) VALUES (?1, ?1, ?2, ?3, 'mcp', NULL, '[]', 0)",
            params![now, title, body],
        )?;
        Ok(c.last_insert_rowid())
    }
}

const MEETING_COLS: &str =
    "SELECT id, started_at, ended_at, title, participants_json, status, summary_md, action_items_json, raw_transcript_md";

fn meeting_row(r: &Row<'_>) -> rusqlite::Result<MeetingRow> {
    let started_at: i64 = r.get(1)?;
    let ended_at: Option<i64> = r.get(2)?;
    let summary_md: Option<String> = r.get(6)?;
    Ok(MeetingRow {
        info: MeetingInfo {
            id: r.get(0)?,
            title: text_col(r, 3)?,
            started_at,
            started_at_iso: iso(started_at),
            ended_at,
            duration_minutes: ended_at.filter(|e| *e >= started_at).map(|e| (e - started_at) / 60),
            status: text_col(r, 5)?,
            participants: parse_names(r.get::<_, Option<String>>(4)?.as_deref()),
            has_summary: summary_md.as_deref().is_some_and(|s| !s.trim().is_empty()),
        },
        summary_md,
        action_items_json: r.get(7)?,
        raw_transcript_md: r.get(8)?,
    })
}

fn note_row(r: &Row<'_>) -> rusqlite::Result<Note> {
    let created_at: i64 = r.get(1)?;
    let updated_at: i64 = r.get(2)?;
    Ok(Note {
        id: r.get(0)?,
        created_at,
        updated_at,
        updated_at_iso: iso(updated_at),
        title: text_col(r, 3)?,
        body_md: Some(text_col(r, 4)?),
        source: text_col(r, 5)?,
        meeting_id: r.get(6)?,
        tags: parse_names(r.get::<_, Option<String>>(7)?.as_deref()),
        pinned: r.get::<_, Option<i64>>(8)?.unwrap_or(0) != 0,
        preview: None,
    })
}

fn transcript_text(c: &Connection, id: i64, row: &MeetingRow) -> Result<String> {
    let segments = tolerate_missing(query_all(
        c,
        "SELECT started_ms, speaker, raw, text FROM segments WHERE meeting_id = ?1 ORDER BY started_ms, id",
        [id],
        |r| {
            let text = text_col(r, 3)?;
            Ok(Segment {
                started_ms: r.get(0)?,
                speaker: text_col(r, 1)?,
                text: if text.trim().is_empty() { text_col(r, 2)? } else { text },
            })
        },
    ))?;
    if segments.is_empty() {
        return Ok(row.raw_transcript_md.clone().unwrap_or_default());
    }
    Ok(segments
        .iter()
        .map(|s| {
            let speaker = if s.speaker.is_empty() { "Unknown" } else { &s.speaker };
            format!("[{}] {}: {}", clock(s.started_ms), speaker, s.text.trim())
        })
        .collect::<Vec<_>>()
        .join("\n"))
}

fn search_notes(c: &Connection, query: &str, limit: usize) -> rusqlite::Result<Vec<Hit>> {
    let hit = |r: &Row<'_>, snippet: String| -> rusqlite::Result<Hit> {
        let at: i64 = r.get(2)?;
        Ok(Hit {
            kind: "note",
            id: r.get(0)?,
            meeting_id: None,
            title: Some(text_col(r, 1)?),
            speaker: None,
            app_id: None,
            at,
            at_iso: iso(at),
            snippet,
        })
    };
    if let Some(m) = fts_query(query) {
        let fts = query_all(
            c,
            "SELECT n.id, n.title, n.updated_at, snippet(notes_fts, -1, '[', ']', '…', 16)
             FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid
             WHERE notes_fts MATCH ?1 ORDER BY rank LIMIT ?2",
            params![m, limit as i64],
            |r| hit(r, text_col(r, 3)?),
        );
        if let Ok(v) = fts {
            return Ok(v);
        }
    }
    let terms = terms(query);
    query_all(
        c,
        "SELECT id, title, updated_at, body_md FROM notes WHERE title LIKE ?1 ESCAPE '\\' OR body_md LIKE ?1 ESCAPE '\\' ORDER BY updated_at DESC LIMIT ?2",
        params![like_pattern(query), limit as i64],
        |r| hit(r, crop(&text_col(r, 3)?, &terms, 160)),
    )
}

fn search_segments(c: &Connection, query: &str, limit: usize) -> rusqlite::Result<Vec<Hit>> {
    let hit = |r: &Row<'_>, snippet: String| -> rusqlite::Result<Hit> {
        let started: Option<i64> = r.get(4)?;
        let at = started.unwrap_or(0) + r.get::<_, i64>(5)? / 1000;
        Ok(Hit {
            kind: "meeting_segment",
            id: r.get(0)?,
            meeting_id: r.get(1)?,
            title: r.get(2)?,
            speaker: Some(text_col(r, 3)?),
            app_id: None,
            at,
            at_iso: iso(at),
            snippet,
        })
    };
    if let Some(m) = fts_query(query) {
        let fts = query_all(
            c,
            "SELECT s.id, s.meeting_id, m.title, s.speaker, m.started_at, s.started_ms, snippet(segments_fts, -1, '[', ']', '…', 16)
             FROM segments_fts JOIN segments s ON s.id = segments_fts.rowid
             LEFT JOIN meetings m ON m.id = s.meeting_id
             WHERE segments_fts MATCH ?1 ORDER BY rank LIMIT ?2",
            params![m, limit as i64],
            |r| hit(r, text_col(r, 6)?),
        );
        if let Ok(v) = fts {
            return Ok(v);
        }
    }
    let terms = terms(query);
    query_all(
        c,
        "SELECT s.id, s.meeting_id, m.title, s.speaker, m.started_at, s.started_ms, s.text
         FROM segments s LEFT JOIN meetings m ON m.id = s.meeting_id
         WHERE s.text LIKE ?1 ESCAPE '\\' ORDER BY m.started_at DESC, s.started_ms LIMIT ?2",
        params![like_pattern(query), limit as i64],
        |r| hit(r, crop(&text_col(r, 6)?, &terms, 160)),
    )
}

fn search_dictations(c: &Connection, query: &str, limit: usize) -> rusqlite::Result<Vec<Hit>> {
    let terms = terms(query);
    query_all(
        c,
        "SELECT id, created_at, app_id, text FROM dictations WHERE text LIKE ?1 ESCAPE '\\' OR raw LIKE ?1 ESCAPE '\\' ORDER BY id DESC LIMIT ?2",
        params![like_pattern(query), limit as i64],
        |r| {
            let at: i64 = r.get(1)?;
            Ok(Hit {
                kind: "dictation",
                id: r.get(0)?,
                meeting_id: None,
                title: None,
                speaker: None,
                app_id: Some(text_col(r, 2)?),
                at,
                at_iso: iso(at),
                snippet: crop(&text_col(r, 3)?, &terms, 160),
            })
        },
    )
}

fn open_ro(path: &Path) -> Result<Option<Connection>> {
    if !path.exists() {
        return Ok(None);
    }
    let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
        .with_context(|| format!("opening {}", path.display()))?;
    c.busy_timeout(Duration::from_secs(2))?;
    Ok(Some(c))
}

fn query_all<T, P: Params>(
    c: &Connection,
    sql: &str,
    p: P,
    f: impl FnMut(&Row<'_>) -> rusqlite::Result<T>,
) -> rusqlite::Result<Vec<T>> {
    c.prepare(sql)?.query_map(p, f)?.collect()
}

/// An existing database that predates a table reads as empty rather than failing.
fn tolerate_missing<T: Default>(r: rusqlite::Result<T>) -> Result<T> {
    match r {
        Err(rusqlite::Error::SqliteFailure(_, Some(m))) if m.starts_with("no such table") => Ok(T::default()),
        other => Ok(other?),
    }
}

fn text_col(r: &Row<'_>, i: usize) -> rusqlite::Result<String> {
    Ok(r.get::<_, Option<String>>(i)?.unwrap_or_default())
}

fn clamp(limit: usize) -> usize {
    limit.clamp(1, MAX_LIMIT)
}

fn interleave(lists: Vec<Vec<Hit>>, limit: usize) -> Vec<Hit> {
    let mut iters: Vec<_> = lists.into_iter().map(|l| l.into_iter()).collect();
    let mut out = vec![];
    loop {
        let mut progressed = false;
        for it in &mut iters {
            if out.len() == limit {
                return out;
            }
            if let Some(h) = it.next() {
                out.push(h);
                progressed = true;
            }
        }
        if !progressed {
            return out;
        }
    }
}

fn terms(query: &str) -> Vec<String> {
    query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(str::to_lowercase)
        .collect()
}

/// Quote every word so user input can't be parsed as FTS5 syntax; the last word matches as a prefix.
fn fts_query(query: &str) -> Option<String> {
    let t = terms(query);
    let last = t.len().checked_sub(1)?;
    Some(
        t.iter()
            .enumerate()
            .map(|(i, w)| if i == last { format!("\"{w}\"*") } else { format!("\"{w}\"") })
            .collect::<Vec<_>>()
            .join(" "),
    )
}

fn like_pattern(query: &str) -> String {
    let mut p = String::from("%");
    for ch in query.trim().chars() {
        if matches!(ch, '%' | '_' | '\\') {
            p.push('\\');
        }
        p.push(ch);
    }
    p.push('%');
    p
}

/// A window of roughly `width` characters around the first matching term.
fn crop(text: &str, terms: &[String], width: usize) -> String {
    let chars: Vec<char> = text.split_whitespace().collect::<Vec<_>>().join(" ").chars().collect();
    if chars.len() <= width {
        return chars.into_iter().collect();
    }
    let lower: Vec<char> = chars.iter().map(|c| c.to_lowercase().next().unwrap_or(*c)).collect();
    let pos = terms
        .iter()
        .filter_map(|t| {
            let needle: Vec<char> = t.chars().collect();
            lower.windows(needle.len().max(1)).position(|w| w == needle.as_slice())
        })
        .min()
        .unwrap_or(0);
    let start = pos.saturating_sub(width / 4);
    let end = (start + width).min(chars.len());
    let mut s: String = chars[start..end].iter().collect();
    if start > 0 {
        s.insert(0, '…');
    }
    if end < chars.len() {
        s.push('…');
    }
    s
}

pub fn iso(ts: i64) -> String {
    DateTime::from_timestamp(ts, 0).map(|d| d.format("%Y-%m-%dT%H:%M:%SZ").to_string()).unwrap_or_default()
}

fn minute_stamp(ts: i64) -> String {
    DateTime::from_timestamp(ts, 0).map(|d| d.format("%Y-%m-%d %H:%M UTC").to_string()).unwrap_or_default()
}

fn date_only(ts: i64) -> String {
    DateTime::from_timestamp(ts, 0).map(|d| d.format("%Y-%m-%d").to_string()).unwrap_or_default()
}

fn clock(ms: i64) -> String {
    let s = (ms / 1000).max(0);
    format!("{:02}:{:02}:{:02}", s / 3600, s % 3600 / 60, s % 60)
}

/// Accepts `["Ana", "Ben"]` or `[{"name": "Ana", "email": ...}]`.
fn parse_names(json: Option<&str>) -> Vec<String> {
    let Some(Value::Array(items)) = json.and_then(|j| serde_json::from_str(j).ok()) else { return vec![] };
    items
        .iter()
        .filter_map(|v| match v {
            Value::String(s) => Some(s.clone()),
            Value::Object(o) => ["name", "email"].iter().find_map(|k| o.get(*k)?.as_str().map(String::from)),
            _ => None,
        })
        .collect()
}

/// Structured items when present, otherwise checkbox lines from the summary.
pub fn parse_action_items(json: Option<&str>, summary_md: Option<&str>) -> Vec<ActionItem> {
    if let Some(Value::Array(items)) = json.and_then(|j| serde_json::from_str(j).ok()) {
        let parsed: Vec<ActionItem> = items.iter().filter_map(action_item).collect();
        if !parsed.is_empty() {
            return parsed;
        }
    }
    summary_md.unwrap_or_default().lines().filter_map(checkbox_line).collect()
}

fn action_item(v: &Value) -> Option<ActionItem> {
    match v {
        Value::String(s) if !s.trim().is_empty() => Some(ActionItem { text: s.trim().into(), owner: None, done: false }),
        Value::Object(o) => {
            let pick = |keys: &[&str]| keys.iter().find_map(|k| o.get(*k)?.as_str().map(|s| s.trim().to_string()));
            let text = pick(&["text", "title", "description", "task", "action"]).filter(|t| !t.is_empty())?;
            let done = o.get("done").or_else(|| o.get("completed")).and_then(Value::as_bool).unwrap_or_else(|| {
                matches!(pick(&["status"]).as_deref(), Some("done" | "completed" | "closed"))
            });
            Some(ActionItem { text, owner: pick(&["owner", "assignee"]).filter(|o| !o.is_empty()), done })
        }
        _ => None,
    }
}

fn checkbox_line(line: &str) -> Option<ActionItem> {
    let rest = line.trim_start().strip_prefix(['-', '*'])?.trim_start();
    let (done, text) = if let Some(t) = rest.strip_prefix("[ ]") {
        (false, t)
    } else {
        (true, rest.strip_prefix("[x]").or_else(|| rest.strip_prefix("[X]"))?)
    };
    let text = text.trim();
    (!text.is_empty()).then(|| ActionItem { text: text.into(), owner: None, done })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fts_query_quotes_and_prefixes_last_word() {
        assert_eq!(fts_query("budget AND \"plan\"").unwrap(), "\"budget\" \"and\" \"plan\"*");
        assert!(fts_query("  !! ").is_none());
    }

    #[test]
    fn crop_centers_on_match() {
        let text = format!("{} needle {}", "a ".repeat(200), "b ".repeat(200));
        let s = crop(&text, &["needle".into()], 80);
        assert!(s.contains("needle"));
        assert!(s.starts_with('…') && s.ends_with('…'));
    }

    #[test]
    fn action_items_from_json_variants() {
        let items = parse_action_items(
            Some(r#"["Send deck", {"text": "Book room", "owner": "Ana", "done": true}, {"title": "Ship", "status": "open"}]"#),
            None,
        );
        assert_eq!(items.len(), 3);
        assert!(items[1].done && items[1].owner.as_deref() == Some("Ana"));
        assert!(!items[2].done);
    }

    #[test]
    fn action_items_fall_back_to_summary_checkboxes() {
        let items = parse_action_items(Some("[]"), Some("Notes\n- [ ] Email Sam\n  * [x] File taxes\n- plain bullet"));
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].text, "Email Sam");
        assert!(items[1].done);
    }

    #[test]
    fn clock_formats_offsets() {
        assert_eq!(clock(3_723_000), "01:02:03");
    }
}
