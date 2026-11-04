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
}
