//! Local dictation history. Raw and cleaned text stay on the machine, in
//! SQLite, for the "swap to raw" shortcut and for reviewing past dictations.
//! Audio is never stored.

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub id: i64,
    pub created_at: i64,
    pub app_id: String,
    pub raw: String,
    pub text: String,
    pub mode: String,
    pub duration_ms: i64,
}

/// Totals over the dictations still in history.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Stats {
    pub dictations: i64,
    pub words: i64,
    /// Time spent talking, in milliseconds.
    pub spoken_ms: i64,
    /// Dictations since the `since` passed to `stats`.
    pub recent_dictations: i64,
    pub recent_words: i64,
}

pub struct History {
    conn: Connection,
}

impl History {
    pub fn open(path: impl AsRef<Path>) -> rusqlite::Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn in_memory() -> rusqlite::Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> rusqlite::Result<Self> {
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS dictations (
                 id          INTEGER PRIMARY KEY,
                 created_at  INTEGER NOT NULL,
                 app_id      TEXT NOT NULL,
                 raw         TEXT NOT NULL,
                 text        TEXT NOT NULL,
                 mode        TEXT NOT NULL,
                 duration_ms INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS dictations_created ON dictations (created_at);",
        )?;
        Ok(History { conn })
    }

    pub fn save(&self, created_at: i64, app_id: &str, raw: &str, text: &str, mode: &str, duration_ms: i64) -> rusqlite::Result<i64> {
        self.conn.execute(
            "INSERT INTO dictations (created_at, app_id, raw, text, mode, duration_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![created_at, app_id, raw, text, mode, duration_ms],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn recent(&self, limit: usize) -> rusqlite::Result<Vec<Entry>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, created_at, app_id, raw, text, mode, duration_ms FROM dictations ORDER BY id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map([limit as i64], row_to_entry)?;
        rows.collect()
    }

    /// Newest first. With a query, only dictations whose text or raw
    /// transcript contains it, ignoring case.
    pub fn search(&self, query: &str, limit: usize) -> rusqlite::Result<Vec<Entry>> {
        let query = query.trim();
        if query.is_empty() {
            return self.recent(limit);
        }
        let escaped = query.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_");
        let pattern = format!("%{escaped}%");
        let mut stmt = self.conn.prepare(
            "SELECT id, created_at, app_id, raw, text, mode, duration_ms FROM dictations
             WHERE text LIKE ?1 ESCAPE '\\' OR raw LIKE ?1 ESCAPE '\\' ORDER BY id DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![pattern, limit as i64], row_to_entry)?;
        rows.collect()
    }

    /// Delete one dictation. False when there was no such entry.
    pub fn delete(&self, id: i64) -> rusqlite::Result<bool> {
        Ok(self.conn.execute("DELETE FROM dictations WHERE id = ?1", [id])? > 0)
    }

    /// Totals over everything kept, and over what was dictated since `since`.
    pub fn stats(&self, since: i64) -> rusqlite::Result<Stats> {
        let mut stats = Stats::default();
        let mut stmt = self.conn.prepare("SELECT created_at, text, duration_ms FROM dictations")?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let created: i64 = row.get(0)?;
            let text: String = row.get(1)?;
            let words = text.split_whitespace().count() as i64;
            stats.dictations += 1;
            stats.words += words;
            stats.spoken_ms += row.get::<_, i64>(2)?;
            if created >= since {
                stats.recent_dictations += 1;
                stats.recent_words += words;
            }
        }
        Ok(stats)
    }

    pub fn last(&self) -> rusqlite::Result<Option<Entry>> {
        self.conn
            .query_row(
                "SELECT id, created_at, app_id, raw, text, mode, duration_ms FROM dictations ORDER BY id DESC LIMIT 1",
                [],
                row_to_entry,
            )
            .optional()
    }

    /// Delete dictations older than `days`. Returns how many were removed.
    pub fn purge_older_than(&self, now: i64, days: u32) -> rusqlite::Result<usize> {
        let cutoff = now - i64::from(days) * 86_400;
        self.conn.execute("DELETE FROM dictations WHERE created_at < ?1", [cutoff])
    }

    pub fn clear(&self) -> rusqlite::Result<usize> {
        self.conn.execute("DELETE FROM dictations", [])
    }
}

fn row_to_entry(r: &rusqlite::Row<'_>) -> rusqlite::Result<Entry> {
    Ok(Entry {
        id: r.get(0)?,
        created_at: r.get(1)?,
        app_id: r.get(2)?,
        raw: r.get(3)?,
        text: r.get(4)?,
        mode: r.get(5)?,
        duration_ms: r.get(6)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn save_recent_and_purge() {
        let h = History::in_memory().unwrap();
        h.save(1_000, "com.apple.mail", "um hi", "Hi", "local", 900).unwrap();
        h.save(1_000_000, "com.apple.mail", "ok", "OK", "local", 300).unwrap();
        assert_eq!(h.last().unwrap().unwrap().text, "OK");
        assert_eq!(h.recent(10).unwrap().len(), 2);
        assert_eq!(h.purge_older_than(1_000_000, 1).unwrap(), 1);
        assert_eq!(h.recent(10).unwrap().len(), 1);
    }

    #[test]
    fn search_delete_and_stats() {
        let h = History::in_memory().unwrap();
        let first = h.save(100, "com.apple.mail", "um ship it", "Ship it.", "local", 1_000).unwrap();
        h.save(200, "com.tinyspeck.slackmacgap", "the build is 100% done", "The build is 100% done.", "local", 2_000).unwrap();

        assert_eq!(h.search("SHIP", 10).unwrap().len(), 1);
        // Found by the raw transcript too.
        assert_eq!(h.search("um", 10).unwrap().len(), 1);
        // % and _ are text, not wildcards.
        assert_eq!(h.search("100%", 10).unwrap().len(), 1);
        assert_eq!(h.search("1_0", 10).unwrap().len(), 0);
        assert_eq!(h.search("  ", 10).unwrap().len(), 2);

        let stats = h.stats(150).unwrap();
        assert_eq!((stats.dictations, stats.words, stats.spoken_ms), (2, 7, 3_000));
        assert_eq!((stats.recent_dictations, stats.recent_words), (1, 5));

        assert!(h.delete(first).unwrap());
        assert!(!h.delete(first).unwrap());
        assert_eq!(h.recent(10).unwrap().len(), 1);
    }
}
