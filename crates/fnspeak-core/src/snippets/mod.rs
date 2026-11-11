//! Snippets: say a trigger phrase, get a saved block of text.
//!
//! Personal snippets are the user's own. Team snippets are pulled from a
//! FnSpeak server and replaced wholesale on every sync. Triggers are
//! matched on whole words anywhere in a dictation, so they have to be
//! distinctive: see `check_trigger`.

pub mod matcher;

pub use crate::vocab::learn::heard_key as trigger_key;
pub use matcher::{expand, find, Match};

use crate::commands::is_command_phrase;
use crate::vocab::learn::is_common_phrase;
use rusqlite::{params, Connection};
use std::collections::HashSet;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

pub const MAX_TRIGGER_CHARS: usize = 60;
pub const MAX_TEXT_CHARS: usize = 4000;

/// Why a trigger was turned down. The message is shown to the user as is.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum TriggerError {
    #[error("Triggers are 1 to 60 characters.")]
    Length,
    #[error("Use at least two words, so it doesn't fire by accident.")]
    TooShort,
    #[error("\"{0}\" is already a spoken command.")]
    Command(String),
    #[error("That's an everyday phrase and would fire by accident. Pick something more distinctive.")]
    Common,
    #[error("You already have a snippet with that trigger.")]
    Duplicate,
}

#[derive(Debug, thiserror::Error)]
pub enum SnippetError {
    #[error("snippets database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error(transparent)]
    Trigger(#[from] TriggerError),
    #[error("Snippet text is 1 to 4000 characters.")]
    TextLength,
    #[error("no such snippet")]
    NotFound,
}

pub type Result<T> = std::result::Result<T, SnippetError>;

/// The rules that don't need the store: length, two words, not a spoken
/// command, not an everyday phrase. Returns the trigger's key.
pub fn check_trigger(trigger: &str) -> std::result::Result<String, TriggerError> {
    let chars = trigger.trim().chars().count();
    if chars == 0 || chars > MAX_TRIGGER_CHARS {
        return Err(TriggerError::Length);
    }
    let key = trigger_key(trigger);
    if key.split(' ').filter(|w| !w.is_empty()).count() < 2 {
        return Err(TriggerError::TooShort);
    }
    if is_command_phrase(&key) {
        return Err(TriggerError::Command(key));
    }
    if is_common_phrase(&key) {
        return Err(TriggerError::Common);
    }
    Ok(key)
}

fn check_text(text: &str) -> Result<()> {
    if text.trim().is_empty() || text.chars().count() > MAX_TEXT_CHARS {
        return Err(SnippetError::TextLength);
    }
    Ok(())
}

/// A team snippet as the server sent it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TeamSnippet {
    pub id: String,
    pub trigger: String,
    pub text: String,
    pub team_id: String,
    pub team_name: String,
    pub can_edit: bool,
    pub updated_at: i64,
}

pub struct SnippetStore {
    conn: Connection,
}

const COLUMNS: &str = "id, trigger_text, trigger_key, body, source, team_id, team_name, can_edit, updated_at";

impl SnippetStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS snippets (
                 id           TEXT PRIMARY KEY,
                 trigger_text TEXT NOT NULL,
                 trigger_key  TEXT NOT NULL,
                 body         TEXT NOT NULL,
                 -- 'personal' or 'team'
                 source       TEXT NOT NULL,
                 team_id      TEXT,
                 team_name    TEXT,
                 can_edit     INTEGER NOT NULL DEFAULT 1,
                 updated_at   INTEGER NOT NULL
             );
             CREATE UNIQUE INDEX IF NOT EXISTS snippets_personal_key
                 ON snippets (trigger_key) WHERE source = 'personal';",
        )?;
        Ok(SnippetStore { conn })
    }

    fn query(&self, filter: &str, order: &str, args: &[&dyn rusqlite::ToSql]) -> Result<Vec<Snippet>> {
        let mut stmt = self.conn.prepare(&format!("SELECT {COLUMNS} FROM snippets WHERE {filter} ORDER BY {order}"))?;
        let rows = stmt.query_map(args, |r| {
            let source: String = r.get(4)?;
            Ok(Snippet {
                id: r.get(0)?,
                trigger: r.get(1)?,
                trigger_key: r.get(2)?,
                text: r.get(3)?,
                source: if source == "team" { SnippetSource::Team } else { SnippetSource::Personal },
                team_id: r.get(5)?,
                team_name: r.get(6)?,
                can_edit: r.get(7)?,
                updated_at: r.get(8)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    /// Every snippet, personal first, then by trigger.
    pub fn list(&self) -> Result<Vec<Snippet>> {
        self.query("1", "source = 'personal' DESC, trigger_key, id", &[])
    }

    /// The snippets that fire: personal ones, plus team ones whose trigger
    /// no personal snippet has. Of two teams' snippets with the same
    /// trigger, the one with the lower id.
    pub fn active(&self) -> Result<Vec<Snippet>> {
        let mut seen = HashSet::new();
        let all = self.query("1", "source = 'personal' DESC, id", &[])?;
        Ok(all.into_iter().filter(|s| seen.insert(s.trigger_key.clone())).collect())
    }

    fn personal(&self, id: &str) -> Result<Snippet> {
        self.query("id = ?1 AND source = 'personal'", "id", &[&id])?.pop().ok_or(SnippetError::NotFound)
    }

    /// Check a trigger for a personal snippet, including that no other
    /// personal snippet has it. `ignoring_id` is the snippet being edited.
    pub fn validate_trigger(&self, trigger: &str, ignoring_id: Option<&str>) -> Result<String> {
        let key = check_trigger(trigger)?;
        let taken: bool = self.conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM snippets WHERE source = 'personal' AND trigger_key = ?1 AND id IS NOT ?2)",
            params![key, ignoring_id],
            |r| r.get(0),
        )?;
        if taken {
            return Err(TriggerError::Duplicate.into());
        }
        Ok(key)
    }

    pub fn add(&mut self, trigger: &str, text: &str) -> Result<Snippet> {
        let key = self.validate_trigger(trigger, None)?;
        check_text(text)?;
        let id: String = self.conn.query_row("SELECT lower(hex(randomblob(16)))", [], |r| r.get(0))?;
        self.conn.execute(
            "INSERT INTO snippets (id, trigger_text, trigger_key, body, source, can_edit, updated_at)
             VALUES (?1, ?2, ?3, ?4, 'personal', 1, ?5)",
            params![id, trigger.trim(), key, text, now_ms()],
        )?;
        self.personal(&id)
    }

    pub fn update(&mut self, id: &str, trigger: &str, text: &str) -> Result<Snippet> {
        self.personal(id)?;
        let key = self.validate_trigger(trigger, Some(id))?;
        check_text(text)?;
        self.conn.execute(
            "UPDATE snippets SET trigger_text = ?2, trigger_key = ?3, body = ?4, updated_at = ?5 WHERE id = ?1",
            params![id, trigger.trim(), key, text, now_ms()],
        )?;
        self.personal(id)
    }

    /// Remove a personal snippet. Team snippets go when the server drops them.
    pub fn remove(&mut self, id: &str) -> Result<bool> {
        Ok(self.conn.execute("DELETE FROM snippets WHERE id = ?1 AND source = 'personal'", [id])? > 0)
    }

    /// Replace every team snippet with what the server has now. The server
    /// doesn't apply the trigger rules, so rows that break them (an everyday
    /// phrase, one word, blank or oversized text) are skipped rather than
    /// pasted into this user's dictation. Returns how many rows were stored.
    pub fn replace_team(&mut self, snippets: Vec<TeamSnippet>) -> Result<usize> {
        let tx = self.conn.transaction()?;
        tx.execute("DELETE FROM snippets WHERE source = 'team'", [])?;
        let mut added = 0;
        for s in snippets {
            let Ok(key) = check_trigger(&s.trigger) else { continue };
            if check_text(&s.text).is_err() {
                continue;
            }
            added += tx.execute(
                "INSERT OR REPLACE INTO snippets (id, trigger_text, trigger_key, body, source, team_id, team_name, can_edit, updated_at)
                 VALUES (?1, ?2, ?3, ?4, 'team', ?5, ?6, ?7, ?8)",
                params![s.id, s.trigger, key, s.text, s.team_id, s.team_name, s.can_edit, s.updated_at],
            )?;
        }
        tx.commit()?;
        Ok(added)
    }
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SnippetSource {
    Personal,
    Team,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snippet {
    pub id: String,
    /// The trigger as the user typed it.
    pub trigger: String,
    /// Lowercase words joined by single spaces; what matching uses.
    pub trigger_key: String,
    /// Inserted exactly as saved.
    pub text: String,
    pub source: SnippetSource,
    pub team_id: Option<String>,
    pub team_name: Option<String>,
    /// Always true for personal snippets.
    pub can_edit: bool,
    /// Unix milliseconds.
    pub updated_at: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn team(id: &str, trigger: &str, text: &str, team_id: &str) -> TeamSnippet {
        TeamSnippet {
            id: id.into(),
            trigger: trigger.into(),
            text: text.into(),
            team_id: team_id.into(),
            team_name: format!("Team {team_id}"),
            can_edit: false,
            updated_at: 1,
        }
    }

    #[test]
    fn trigger_rules() {
        assert_eq!(check_trigger("  My Calendar link "), Ok("my calendar link".to_string()));
        assert_eq!(check_trigger(""), Err(TriggerError::Length));
        assert_eq!(check_trigger(&"calendar link ".repeat(6)), Err(TriggerError::Length));
        assert_eq!(check_trigger("calendar"), Err(TriggerError::TooShort));
        assert_eq!(check_trigger("Scratch that"), Err(TriggerError::Command("scratch that".into())));
        // Every word is an everyday one.
        assert_eq!(check_trigger("sign off"), Err(TriggerError::Common));
    }

    #[test]
    fn adds_updates_and_removes_personal_snippets() {
        let mut store = SnippetStore::in_memory().unwrap();
        let s = store.add(" my calendar link ", "https://cal.com/ryan").unwrap();
        assert_eq!((s.trigger.as_str(), s.trigger_key.as_str()), ("my calendar link", "my calendar link"));
        assert_eq!((s.source, s.can_edit), (SnippetSource::Personal, true));
        assert_eq!(s.id.len(), 32);

        // Same key, different case: taken. Editing the snippet itself: fine.
        assert!(matches!(store.add("My Calendar Link", "x"), Err(SnippetError::Trigger(TriggerError::Duplicate))));
        assert!(store.validate_trigger("My Calendar Link", Some(&s.id)).is_ok());

        let changed = store.update(&s.id, "my booking link", "https://cal.com/r").unwrap();
        assert_eq!((changed.trigger_key.as_str(), changed.text.as_str()), ("my booking link", "https://cal.com/r"));
        assert!(matches!(store.update("nope", "my booking page", "x"), Err(SnippetError::NotFound)));

        assert!(matches!(store.add("office address", "   "), Err(SnippetError::TextLength)));
        assert!(matches!(store.add("office address", &"x".repeat(4001)), Err(SnippetError::TextLength)));

        assert!(store.remove(&s.id).unwrap());
        assert!(!store.remove(&s.id).unwrap());
        assert!(store.list().unwrap().is_empty());
    }

    #[test]
    fn team_snippets_are_replaced_wholesale_and_cannot_be_edited_locally() {
        let mut store = SnippetStore::in_memory().unwrap();
        let mine = store.add("office address", "1 Main St").unwrap();
        assert_eq!(store.replace_team(vec![team("t1", "onboarding checklist", "9 to 5", "a")]).unwrap(), 1);
        assert_eq!(store.replace_team(vec![team("t2", "status page", "status.example.com", "a")]).unwrap(), 1);

        let all = store.list().unwrap();
        assert_eq!(all.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), vec![mine.id.as_str(), "t2"]);
        assert_eq!(all[1].team_name.as_deref(), Some("Team a"));

        // update and remove only touch personal snippets.
        assert!(matches!(store.update("t2", "status board", "x"), Err(SnippetError::NotFound)));
        assert!(!store.remove("t2").unwrap());

        assert_eq!(store.replace_team(vec![]).unwrap(), 0);
        assert_eq!(store.list().unwrap().len(), 1);
    }

    #[test]
    fn replace_team_skips_rows_that_break_the_trigger_rules() {
        let mut store = SnippetStore::in_memory().unwrap();
        let stored = store
            .replace_team(vec![
                team("t1", "sign off", "Best regards", "a"),
                team("t2", "support", "one word", "a"),
                team("t3", "office address", "   ", "a"),
                team("t4", "office hours", &"x".repeat(4001), "a"),
                team("t5", "status page", "status.example.com", "a"),
            ])
            .unwrap();
        assert_eq!(stored, 1);
        let all = store.list().unwrap();
        assert_eq!(all.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), vec!["t5"]);
    }

    #[test]
    fn active_prefers_personal_then_the_lower_team_id() {
        let mut store = SnippetStore::in_memory().unwrap();
        store.add("office address", "MINE").unwrap();
        store
            .replace_team(vec![
                team("t9", "Office Address", "TEAM", "a"),
                team("t2", "status page", "SECOND", "b"),
                team("t1", "status page", "FIRST", "a"),
            ])
            .unwrap();
        let mut active: Vec<(String, String)> = store.active().unwrap().into_iter().map(|s| (s.trigger_key, s.text)).collect();
        active.sort();
        assert_eq!(active, vec![("office address".into(), "MINE".into()), ("status page".into(), "FIRST".into())]);
    }

    #[test]
    fn survives_reopening() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("snippets.db");
        SnippetStore::open(&path).unwrap().add("office address", "1 Main St").unwrap();
        assert_eq!(SnippetStore::open(&path).unwrap().list().unwrap().len(), 1);
    }
}
