//! Writing notes and meetings that came from a sync server. Unlike the
//! regular edit paths these keep the timestamps they're given, so a pulled
//! item looks the same on every device, and a meeting arrives whole: its
//! fields and transcript segments in one transaction.

use rusqlite::{params, Result};

use super::{to_json, ActionItem, Meeting, MeetingStatus, Note, NoteDraft, NotesStore};

/// A transcript line from the server. Only the cleaned-up text is synced, so
/// it doubles as the raw text locally.
#[derive(Clone, Debug, PartialEq)]
pub struct SegmentImport {
    pub started_ms: i64,
    pub ended_ms: i64,
    pub speaker: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeetingImport {
    pub started_at: i64,
    pub ended_at: Option<i64>,
    pub title: String,
    pub participants: Vec<String>,
    pub status: MeetingStatus,
    pub summary_md: Option<String>,
    pub action_items: Vec<ActionItem>,
    pub raw_transcript_md: Option<String>,
    pub segments: Vec<SegmentImport>,
}

impl NotesStore {
    /// Create (`id` None) or overwrite a note with the given timestamps.
    /// Overwriting a note that's gone creates it again.
    pub fn put_synced_note(&self, id: Option<i64>, draft: &NoteDraft, created_at: i64, updated_at: i64) -> Result<Note> {
        let tags = to_json(&draft.tags);
        if let Some(id) = id {
            let changed = self.conn.execute(
                "UPDATE notes SET created_at = ?2, updated_at = ?3, title = ?4, body_md = ?5, source = ?6, meeting_id = ?7,
                                  tags_json = ?8, pinned = ?9
                 WHERE id = ?1",
                params![id, created_at, updated_at, draft.title, draft.body_md, draft.source.as_str(), draft.meeting_id, tags, draft.pinned],
            )?;
            if changed > 0 {
                return self.note(id)?.ok_or(rusqlite::Error::QueryReturnedNoRows);
            }
        }
        self.conn.execute(
            "INSERT INTO notes (created_at, updated_at, title, body_md, source, meeting_id, tags_json, pinned)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![created_at, updated_at, draft.title, draft.body_md, draft.source.as_str(), draft.meeting_id, tags, draft.pinned],
        )?;
        self.note(self.conn.last_insert_rowid())?.ok_or(rusqlite::Error::QueryReturnedNoRows)
    }

    /// Create (`id` None) or replace a meeting and all its segments. A
    /// replaced meeting keeps its calendar event link.
    pub fn put_synced_meeting(&self, id: Option<i64>, m: &MeetingImport) -> Result<Meeting> {
        let tx = self.conn.unchecked_transaction()?;
        let participants = to_json(&m.participants);
        let action_items = to_json(&m.action_items);
        let existing = match id {
            Some(id) => tx.execute(
                "UPDATE meetings SET started_at = ?2, ended_at = ?3, title = ?4, participants_json = ?5, status = ?6,
                                     summary_md = ?7, action_items_json = ?8, raw_transcript_md = ?9
                 WHERE id = ?1",
                params![id, m.started_at, m.ended_at, m.title, participants, m.status.as_str(), m.summary_md, action_items, m.raw_transcript_md],
            )? > 0,
            None => false,
        };
        let id = match (id, existing) {
            (Some(id), true) => {
                tx.execute("DELETE FROM segments WHERE meeting_id = ?1", [id])?;
                id
            }
            _ => {
                tx.execute(
                    "INSERT INTO meetings (started_at, ended_at, title, participants_json, status, summary_md, action_items_json,
                                           raw_transcript_md)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    params![m.started_at, m.ended_at, m.title, participants, m.status.as_str(), m.summary_md, action_items, m.raw_transcript_md],
                )?;
                tx.last_insert_rowid()
            }
        };
        {
            // Raw and text both get the synced text.
            let mut insert = tx.prepare(
                "INSERT INTO segments (meeting_id, started_ms, ended_ms, speaker, raw, text) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            )?;
            for s in &m.segments {
                insert.execute(params![id, s.started_ms, s.ended_ms, s.speaker, s.text])?;
            }
        }
        tx.commit()?;
        self.meeting_row(id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notes::{HitKind, NoteSource};

    fn imported(title: &str, segments: &[(&str, &str)]) -> MeetingImport {
        MeetingImport {
            started_at: 1_700_000_000,
            ended_at: Some(1_700_000_600),
            title: title.into(),
            participants: vec!["Priya".into()],
            status: MeetingStatus::Done,
            summary_md: Some("## Summary\n- Ship it".into()),
            action_items: vec![ActionItem { owner: None, task: "Ship it".into(), due: None, done: false }],
            raw_transcript_md: Some("[00:00:00] Me: hello\n".into()),
            segments: segments
                .iter()
                .enumerate()
                .map(|(i, (speaker, text))| SegmentImport {
                    started_ms: i as i64 * 1000,
                    ended_ms: i as i64 * 1000 + 900,
                    speaker: speaker.to_string(),
                    text: text.to_string(),
                })
                .collect(),
        }
    }

    #[test]
    fn synced_notes_keep_their_timestamps() {
        let store = NotesStore::in_memory().unwrap();
        let draft = NoteDraft { title: "Pulled".into(), body_md: "from the laptop".into(), ..Default::default() };
        let n = store.put_synced_note(None, &draft, 100, 200).unwrap();
        assert_eq!((n.created_at, n.updated_at, n.source), (100, 200, NoteSource::Quick));

        let edited = NoteDraft { body_md: "edited on the laptop".into(), ..draft.clone() };
        let n2 = store.put_synced_note(Some(n.id), &edited, 100, 300).unwrap();
        assert_eq!((n2.id, n2.updated_at, n2.body_md.as_str()), (n.id, 300, "edited on the laptop"));
        assert_eq!(store.search("laptop", 10).unwrap().len(), 1);

        // Overwriting a note deleted locally brings it back.
        store.delete_note(n.id).unwrap();
        let n3 = store.put_synced_note(Some(n.id), &edited, 100, 400).unwrap();
        assert_eq!((n3.updated_at, store.notes(10).unwrap().len()), (400, 1));
    }

    #[test]
    fn synced_meetings_replace_their_segments() {
        let store = NotesStore::in_memory().unwrap();
        let m = store.put_synced_meeting(None, &imported("Launch sync", &[("me", "hello"), ("others", "pgvector rollout")])).unwrap();
        assert_eq!((m.started_at, m.status, m.title.as_str()), (1_700_000_000, MeetingStatus::Done, "Launch sync"));
        assert_eq!(store.segments(m.id).unwrap().len(), 2);
        assert_eq!(store.search("pgvector", 10).unwrap()[0].kind, HitKind::Segment);

        let again = store.put_synced_meeting(Some(m.id), &imported("Launch sync v2", &[("me", "bye")])).unwrap();
        assert_eq!(again.id, m.id);
        let segments = store.segments(m.id).unwrap();
        assert_eq!(segments.len(), 1);
        assert_eq!((segments[0].raw.as_str(), segments[0].text.as_str()), ("bye", "bye"));
        assert!(store.search("pgvector", 10).unwrap().is_empty());
        assert_eq!(store.search("v2", 10).unwrap()[0].kind, HitKind::Meeting);
    }
}
