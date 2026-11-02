//! Notes and meetings: storage, visibility, last-writer-wins sync and search.
//!
//! An item belongs to the user who pushed it. Its owner can share it with
//! one of their teams (`shared_with_team_id` + `visibility = "team"`), which
//! lets every member read it; only the owner can change it. Shared by the
//! REST handlers and the MCP tools so both see exactly the same data.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

use crate::args;
use crate::db::{Backend, Batch, Db, Row};
use crate::error::{ApiError, ApiResult};

/// Rows the caller can read; `$1` must be the caller's user id.
const VISIBLE: &str = "(x.user_id = $1 OR (x.visibility = 'team' AND x.shared_with_team_id IN \
                       (SELECT team_id FROM memberships WHERE user_id = $1)))";

const NOTE_COLS: &str = "x.id, x.user_id, x.shared_with_team_id, x.visibility, x.created_at, x.updated_at, x.title, \
                         x.body_md, x.source, x.meeting_id, x.tags_json, x.pinned, x.deleted, x.seq";
const MEETING_COLS: &str = "x.id, x.user_id, x.shared_with_team_id, x.visibility, x.started_at, x.ended_at, \
                            x.updated_at, x.title, x.participants_json, x.status, x.summary_md, x.action_items_json, \
                            x.deleted, x.seq, x.raw_transcript_md";

const NEXT_SEQ: &str = "UPDATE sync_counter SET value = value + 1 WHERE id = 1";
const CURRENT_SEQ: &str = "(SELECT value FROM sync_counter WHERE id = 1)";

const MAX_TITLE_CHARS: usize = 1_000;
const MAX_BODY_BYTES: usize = 2 * 1024 * 1024;
const MAX_TRANSCRIPT_BYTES: usize = 12 * 1024 * 1024;
const MAX_SEGMENTS: usize = 50_000;

#[derive(Clone, Debug, Serialize)]
pub struct Note {
    pub id: String,
    pub user_id: String,
    pub shared_with_team_id: Option<String>,
    pub visibility: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub title: String,
    pub body_md: String,
    pub source: String,
    pub meeting_id: Option<String>,
    pub tags_json: String,
    pub pinned: bool,
    pub deleted: bool,
    pub seq: i64,
}

impl Note {
    fn from_row(r: &Row) -> Note {
        Note {
            id: r.text(0),
            user_id: r.text(1),
            shared_with_team_id: r.opt_text(2),
            visibility: r.text(3),
            created_at: r.int(4),
            updated_at: r.int(5),
            title: r.text(6),
            body_md: r.text(7),
            source: r.text(8),
            meeting_id: r.opt_text(9),
            tags_json: r.text(10),
            pinned: r.bool(11),
            deleted: r.bool(12),
            seq: r.int(13),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Segment {
    pub started_ms: i64,
    pub ended_ms: i64,
    #[serde(default)]
    pub speaker: String,
    pub text: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct Meeting {
    pub id: String,
    pub user_id: String,
    pub shared_with_team_id: Option<String>,
    pub visibility: String,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub updated_at: i64,
    pub title: String,
    pub participants_json: String,
    pub status: String,
    pub summary_md: String,
    pub action_items_json: String,
    pub deleted: bool,
    pub seq: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw_transcript_md: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub segments: Option<Vec<Segment>>,
}

impl Meeting {
    fn from_row(r: &Row, with_transcript: bool) -> Meeting {
        Meeting {
            id: r.text(0),
            user_id: r.text(1),
            shared_with_team_id: r.opt_text(2),
            visibility: r.text(3),
            started_at: r.int(4),
            ended_at: r.opt_int(5),
            updated_at: r.int(6),
            title: r.text(7),
            participants_json: r.text(8),
            status: r.text(9),
            summary_md: r.text(10),
            action_items_json: r.text(11),
            deleted: r.bool(12),
            seq: r.int(13),
            raw_transcript_md: with_transcript.then(|| r.text(14)),
            segments: None,
        }
    }
}

/// A note as pushed by a client. `*_json` fields take a JSON string (as
/// the app stores them) or the JSON value itself.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct NoteIn {
    pub id: String,
    pub created_at: Option<i64>,
    pub updated_at: i64,
    pub title: String,
    pub body_md: String,
    pub source: String,
    pub meeting_id: Option<String>,
    pub tags_json: Option<Value>,
    #[serde(deserialize_with = "bool_or_int")]
    pub pinned: bool,
    pub shared_with_team_id: Option<String>,
    pub visibility: Option<String>,
    #[serde(deserialize_with = "bool_or_int")]
    pub deleted: bool,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct MeetingIn {
    pub id: String,
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub updated_at: i64,
    pub title: String,
    pub participants_json: Option<Value>,
    pub status: String,
    pub summary_md: String,
    pub action_items_json: Option<Value>,
    pub raw_transcript_md: String,
    pub shared_with_team_id: Option<String>,
    pub visibility: Option<String>,
    #[serde(deserialize_with = "bool_or_int")]
    pub deleted: bool,
    /// When present, replaces the meeting's segments.
    pub segments: Option<Vec<Segment>>,
}

fn bool_or_int<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Bool(b) => b,
        Value::Number(n) => n.as_i64().unwrap_or(0) != 0,
        _ => false,
    })
}

fn json_text(v: Option<Value>, default: &str, field: &str) -> ApiResult<String> {
    match v {
        None | Some(Value::Null) => Ok(default.to_string()),
        Some(Value::String(s)) => {
            serde_json::from_str::<Value>(&s).map_err(|_| ApiError::bad(format!("{field} is not valid JSON")))?;
            Ok(s)
        }
        Some(other) => Ok(other.to_string()),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WriteOutcome {
    /// Stored; it was newer than what the server had.
    Applied,
    /// The server already has a version with the same or later `updated_at`.
    Stale,
    /// The id belongs to someone else's item.
    Forbidden,
}

fn check_id(id: &str) -> ApiResult<()> {
    uuid::Uuid::parse_str(id).map_err(|_| ApiError::bad(format!("id {id:?} is not a UUID")))?;
    Ok(())
}

fn check_len(value: &str, max: usize, field: &str) -> ApiResult<()> {
    if value.len() > max {
        return Err(ApiError::bad(format!("{field} is too long")));
    }
    Ok(())
}

/// Validate sharing and return the visibility to store.
async fn sharing(db: &Db, user_id: &str, team_id: &Option<String>, visibility: &Option<String>) -> ApiResult<String> {
    let visibility = match visibility.as_deref() {
        Some("private") => "private",
        Some("team") => "team",
        Some(other) => return Err(ApiError::bad(format!("visibility must be private or team, not {other:?}"))),
        None if team_id.is_some() => "team",
        None => "private",
    };
    match team_id {
        Some(team) => {
            let member = db
                .query_opt("SELECT 1 FROM memberships WHERE team_id = $1 AND user_id = $2", args![team, user_id])
                .await?;
            if member.is_none() {
                return Err(ApiError::forbidden("you can only share with teams you belong to"));
            }
        }
        None if visibility == "team" => return Err(ApiError::bad("visibility \"team\" needs shared_with_team_id")),
        None => {}
    }
    Ok(visibility.to_string())
}

async fn outcome(db: &Db, table: &str, id: &str, user_id: &str, applied: bool) -> ApiResult<WriteOutcome> {
    if applied {
        return Ok(WriteOutcome::Applied);
    }
    let owner = db.query_opt(&format!("SELECT user_id FROM {table} WHERE id = $1"), args![id]).await?;
    Ok(match owner {
        Some(r) if r.text(0) == user_id => WriteOutcome::Stale,
        _ => WriteOutcome::Forbidden,
    })
}

pub async fn upsert_note(db: &Db, user_id: &str, mut n: NoteIn) -> ApiResult<WriteOutcome> {
    check_id(&n.id)?;
    if n.updated_at <= 0 {
        return Err(ApiError::bad("updated_at is required"));
    }
    if n.deleted {
        // Tombstones keep only what sync needs.
        n.title.clear();
        n.body_md.clear();
        n.tags_json = None;
    }
    check_len(&n.title, MAX_TITLE_CHARS * 4, "title")?;
    check_len(&n.body_md, MAX_BODY_BYTES, "body_md")?;
    let visibility = sharing(db, user_id, &n.shared_with_team_id, &n.visibility).await?;
    let tags = json_text(n.tags_json.take(), "[]", "tags_json")?;
    let mut batch = Batch::default();
    batch.push(NEXT_SEQ, args![]).push(
        format!(
            "INSERT INTO notes (id, user_id, shared_with_team_id, visibility, created_at, updated_at, title, body_md,
                                source, meeting_id, tags_json, pinned, deleted, seq)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, {CURRENT_SEQ})
             ON CONFLICT (id) DO UPDATE SET
                 shared_with_team_id = excluded.shared_with_team_id, visibility = excluded.visibility,
                 created_at = excluded.created_at, updated_at = excluded.updated_at, title = excluded.title,
                 body_md = excluded.body_md, source = excluded.source, meeting_id = excluded.meeting_id,
                 tags_json = excluded.tags_json, pinned = excluded.pinned, deleted = excluded.deleted,
                 seq = excluded.seq
             WHERE notes.user_id = excluded.user_id AND excluded.updated_at > notes.updated_at"
        ),
        args![
            &n.id,
            user_id,
            n.shared_with_team_id,
            visibility,
            n.created_at.unwrap_or(n.updated_at),
            n.updated_at,
            n.title,
            n.body_md,
            n.source,
            n.meeting_id,
            tags,
            n.pinned,
            n.deleted,
        ],
    );
    let changed = db.transaction(batch.0).await?;
    outcome(db, "notes", &n.id, user_id, changed[1] == 1).await
}

pub async fn upsert_meeting(db: &Db, user_id: &str, mut m: MeetingIn) -> ApiResult<WriteOutcome> {
    check_id(&m.id)?;
    if m.updated_at <= 0 || m.started_at <= 0 {
        return Err(ApiError::bad("started_at and updated_at are required"));
    }
    if m.deleted {
        m.title.clear();
        m.summary_md.clear();
        m.raw_transcript_md.clear();
        m.participants_json = None;
        m.action_items_json = None;
        m.segments = Some(Vec::new());
    }
    check_len(&m.title, MAX_TITLE_CHARS * 4, "title")?;
    check_len(&m.summary_md, MAX_BODY_BYTES, "summary_md")?;
    check_len(&m.raw_transcript_md, MAX_TRANSCRIPT_BYTES, "raw_transcript_md")?;
    if m.segments.as_ref().is_some_and(|s| s.len() > MAX_SEGMENTS) {
        return Err(ApiError::bad("too many segments"));
    }
    let visibility = sharing(db, user_id, &m.shared_with_team_id, &m.visibility).await?;
    let participants = json_text(m.participants_json.take(), "[]", "participants_json")?;
    let action_items = json_text(m.action_items_json.take(), "[]", "action_items_json")?;

    let mut batch = Batch::default();
    batch.push(NEXT_SEQ, args![]).push(
        format!(
            "INSERT INTO meetings (id, user_id, shared_with_team_id, visibility, started_at, ended_at, updated_at, title,
                                   participants_json, status, summary_md, action_items_json, raw_transcript_md,
                                   deleted, seq)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, {CURRENT_SEQ})
             ON CONFLICT (id) DO UPDATE SET
                 shared_with_team_id = excluded.shared_with_team_id, visibility = excluded.visibility,
                 started_at = excluded.started_at, ended_at = excluded.ended_at, updated_at = excluded.updated_at,
                 title = excluded.title, participants_json = excluded.participants_json, status = excluded.status,
                 summary_md = excluded.summary_md, action_items_json = excluded.action_items_json,
                 raw_transcript_md = excluded.raw_transcript_md, deleted = excluded.deleted, seq = excluded.seq
             WHERE meetings.user_id = excluded.user_id AND excluded.updated_at > meetings.updated_at"
        ),
        args![
            &m.id,
            user_id,
            m.shared_with_team_id,
            visibility,
            m.started_at,
            m.ended_at,
            m.updated_at,
            m.title,
            participants,
            m.status,
            m.summary_md,
            action_items,
            m.raw_transcript_md,
            m.deleted,
        ],
    );
    if let Some(segments) = &m.segments {
        // Only touch segments if the meeting write above won, which is
        // exactly when its seq is the one this transaction just took.
        let won = format!("EXISTS (SELECT 1 FROM meetings WHERE id = $1 AND seq = {CURRENT_SEQ})");
        batch.push(format!("DELETE FROM segments WHERE meeting_id = $1 AND {won}"), args![&m.id]);
        for (i, s) in segments.iter().enumerate() {
            batch.push(
                format!(
                    "INSERT INTO segments (meeting_id, position, started_ms, ended_ms, speaker, text)
                     SELECT $1, $2, $3, $4, $5, $6 WHERE {won}"
                ),
                args![&m.id, i as i64, s.started_ms, s.ended_ms, &s.speaker, &s.text],
            );
        }
    }
    let changed = db.transaction(batch.0).await?;
    outcome(db, "meetings", &m.id, user_id, changed[1] == 1).await
}

pub async fn get_note(db: &Db, user_id: &str, id: &str) -> ApiResult<Option<Note>> {
    let row = db
        .query_opt(&format!("SELECT {NOTE_COLS} FROM notes x WHERE x.id = $2 AND {VISIBLE}"), args![user_id, id])
        .await?;
    Ok(row.as_ref().map(Note::from_row))
}

pub async fn list_notes(db: &Db, user_id: &str, limit: i64, offset: i64) -> ApiResult<Vec<Note>> {
    let rows = db
        .query(
            &format!(
                "SELECT {NOTE_COLS} FROM notes x WHERE x.deleted = 0 AND {VISIBLE}
                 ORDER BY x.pinned DESC, x.updated_at DESC LIMIT $2 OFFSET $3"
            ),
            args![user_id, limit.clamp(1, 500), offset.max(0)],
        )
        .await?;
    Ok(rows.iter().map(Note::from_row).collect())
}

pub async fn get_meeting(
    db: &Db,
    user_id: &str,
    id: &str,
    with_transcript: bool,
    with_segments: bool,
) -> ApiResult<Option<Meeting>> {
    let row = db
        .query_opt(&format!("SELECT {MEETING_COLS} FROM meetings x WHERE x.id = $2 AND {VISIBLE}"), args![user_id, id])
        .await?;
    let Some(row) = row else { return Ok(None) };
    let mut meeting = Meeting::from_row(&row, with_transcript);
    if with_segments {
        meeting.segments = Some(segments(db, id).await?);
    }
    Ok(Some(meeting))
}

/// Meetings that started at or after `since`, newest first.
pub async fn list_meetings(db: &Db, user_id: &str, since: Option<i64>, limit: i64) -> ApiResult<Vec<Meeting>> {
    let rows = db
        .query(
            &format!(
                "SELECT {MEETING_COLS} FROM meetings x WHERE x.deleted = 0 AND x.started_at >= $2 AND {VISIBLE}
                 ORDER BY x.started_at DESC LIMIT $3"
            ),
            args![user_id, since.unwrap_or(0), limit.clamp(1, 500)],
        )
        .await?;
    Ok(rows.iter().map(|r| Meeting::from_row(r, false)).collect())
}

pub async fn segments(db: &Db, meeting_id: &str) -> ApiResult<Vec<Segment>> {
    let rows = db
        .query(
            "SELECT started_ms, ended_ms, speaker, text FROM segments WHERE meeting_id = $1 ORDER BY position",
            args![meeting_id],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| Segment { started_ms: r.int(0), ended_ms: r.int(1), speaker: r.text(2), text: r.text(3) })
        .collect())
}

pub struct Changes {
    pub notes: Vec<Note>,
    pub meetings: Vec<Meeting>,
    /// Pass back as `since` to continue.
    pub cursor: i64,
    pub more: bool,
}

/// Everything the caller can see that changed after `since`, oldest first,
/// including tombstones. Meetings come with transcript and segments.
pub async fn changes_since(db: &Db, user_id: &str, since: i64, limit: i64) -> ApiResult<Changes> {
    let limit = limit.clamp(1, 1000);
    let notes: Vec<Note> = db
        .query(
            &format!("SELECT {NOTE_COLS} FROM notes x WHERE x.seq > $2 AND {VISIBLE} ORDER BY x.seq LIMIT $3"),
            args![user_id, since, limit + 1],
        )
        .await?
        .iter()
        .map(Note::from_row)
        .collect();
    let meetings: Vec<Meeting> = db
        .query(
            &format!("SELECT {MEETING_COLS} FROM meetings x WHERE x.seq > $2 AND {VISIBLE} ORDER BY x.seq LIMIT $3"),
            args![user_id, since, limit + 1],
        )
        .await?
        .iter()
        .map(|r| Meeting::from_row(r, true))
        .collect();

    // Take the `limit` lowest seqs across both tables, so the cursor never
    // skips an item from the table that had fewer changes.
    let mut seqs: Vec<i64> = notes.iter().map(|n| n.seq).chain(meetings.iter().map(|m| m.seq)).collect();
    seqs.sort_unstable();
    let more = seqs.len() as i64 > limit;
    let cursor = if more { seqs[limit as usize - 1] } else { seqs.last().copied().unwrap_or(since) };

    let notes: Vec<Note> = notes.into_iter().filter(|n| n.seq <= cursor).collect();
    let mut kept = Vec::new();
    for mut m in meetings.into_iter().filter(|m| m.seq <= cursor) {
        m.segments = Some(segments(db, &m.id).await?);
        kept.push(m);
    }
    Ok(Changes { notes, meetings: kept, cursor, more })
}

#[derive(Clone, Debug, Serialize)]
pub struct SearchHit {
    pub kind: &'static str,
    pub id: String,
    pub title: String,
    pub snippet: String,
    /// `updated_at` for notes, `started_at` for meetings.
    pub at: i64,
    #[serde(skip)]
    rank: f64,
}

/// Full-text search over notes and meetings the caller can see, best first.
pub async fn search(db: &Db, user_id: &str, query: &str, limit: i64) -> ApiResult<Vec<SearchHit>> {
    let limit = limit.clamp(1, 100);
    let (note_sql, meeting_sql, q) = match db.backend() {
        Backend::Sqlite => {
            let Some(q) = fts5_query(query) else { return Ok(Vec::new()) };
            (
                format!(
                    "SELECT x.id, x.title, snippet(notes_fts, -1, '**', '**', '…', 16), x.updated_at,
                            bm25(notes_fts, 4.0, 1.0)
                     FROM notes_fts JOIN notes x ON x.pk = notes_fts.rowid
                     WHERE notes_fts MATCH $2 AND x.deleted = 0 AND {VISIBLE}
                     ORDER BY bm25(notes_fts, 4.0, 1.0) LIMIT $3"
                ),
                format!(
                    "SELECT x.id, x.title, snippet(meetings_fts, -1, '**', '**', '…', 16), x.started_at,
                            bm25(meetings_fts, 4.0, 2.0, 1.0)
                     FROM meetings_fts JOIN meetings x ON x.pk = meetings_fts.rowid
                     WHERE meetings_fts MATCH $2 AND x.deleted = 0 AND {VISIBLE}
                     ORDER BY bm25(meetings_fts, 4.0, 2.0, 1.0) LIMIT $3"
                ),
                q,
            )
        }
        #[cfg(feature = "postgres")]
        Backend::Postgres => {
            if query.trim().is_empty() {
                return Ok(Vec::new());
            }
            // Negated so that, as with bm25, lower is better.
            (
                format!(
                    "SELECT x.id, x.title, ts_headline('simple', x.body_md, q, 'StartSel=**, StopSel=**, MaxWords=24, MinWords=8'),
                            x.updated_at, -ts_rank(x.search, q)
                     FROM notes x, websearch_to_tsquery('simple', $2) q
                     WHERE x.search @@ q AND x.deleted = 0 AND {VISIBLE}
                     ORDER BY ts_rank(x.search, q) DESC LIMIT $3"
                ),
                format!(
                    "SELECT x.id, x.title, ts_headline('simple', x.summary_md || ' ' || x.raw_transcript_md, q,
                                                       'StartSel=**, StopSel=**, MaxWords=24, MinWords=8'),
                            x.started_at, -ts_rank(x.search, q)
                     FROM meetings x, websearch_to_tsquery('simple', $2) q
                     WHERE x.search @@ q AND x.deleted = 0 AND {VISIBLE}
                     ORDER BY ts_rank(x.search, q) DESC LIMIT $3"
                ),
                query.to_string(),
            )
        }
    };
    let hit = |kind: &'static str| {
        move |r: &Row| SearchHit { kind, id: r.text(0), title: r.text(1), snippet: r.text(2), at: r.int(3), rank: r.real(4) }
    };
    let mut hits: Vec<SearchHit> = db.query(&note_sql, args![user_id, &q, limit]).await?.iter().map(hit("note")).collect();
    hits.extend(db.query(&meeting_sql, args![user_id, &q, limit]).await?.iter().map(hit("meeting")));
    hits.sort_by(|a, b| a.rank.total_cmp(&b.rank));
    hits.truncate(limit as usize);
    Ok(hits)
}

/// Turn user input into an FTS5 query: every word must match, the last one
/// as a prefix. Quoting each word keeps FTS5 syntax out of user hands.
fn fts5_query(input: &str) -> Option<String> {
    let words: Vec<String> = input
        .split(|c: char| !c.is_alphanumeric() && c != '\'' && c != '-')
        .map(|w| w.trim_matches(|c| c == '\'' || c == '-'))
        .filter(|w| !w.is_empty())
        .map(|w| format!("\"{w}\""))
        .collect();
    if words.is_empty() {
        return None;
    }
    Some(format!("{}*", words.join(" ")))
}

#[cfg(test)]
mod tests {
    use super::fts5_query;

    #[test]
    fn builds_safe_fts_queries() {
        assert_eq!(fts5_query("pgvector rollout").as_deref(), Some("\"pgvector\" \"rollout\"*"));
        assert_eq!(fts5_query("title:x OR \"y").as_deref(), Some("\"title\" \"x\" \"OR\" \"y\"*"));
        assert_eq!(fts5_query("  ** "), None);
    }
}
