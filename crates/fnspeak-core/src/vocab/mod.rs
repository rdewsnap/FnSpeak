//! Personal vocabulary: the names and terms that generic dictation gets wrong.
//!
//! Terms come from sources (project folders, contacts, calendar, the user's
//! own additions, and what they fixed after dictating) and live in SQLite. Lookup is
//! phonetic rather than semantic: a misheard name is a sound-alike problem
//! ("kin ju" → "Kinju"), so Double Metaphone codes do the heavy lifting and a
//! string-similarity score breaks ties.

pub mod learn;
pub mod projects;

pub use learn::{apply_corrections, corrections_from_edit, LearnedCorrection};

use rphonetic::DoubleMetaphone;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Suggestions at or above this score are applied automatically when no
/// cleanup model runs. Below it they're only passed to the model as hints.
pub const AUTO_APPLY_SCORE: f64 = 0.92;
/// Minimum score for a suggestion to be worth showing the cleanup model.
pub const HINT_SCORE: f64 = 0.75;
/// Spoken windows up to this many words can collapse into one term.
const MAX_WINDOW: usize = 3;

#[derive(Debug, thiserror::Error)]
pub enum VocabError {
    #[error("vocabulary database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, VocabError>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Project,
    Contact,
    Calendar,
    User,
    Correction,
    /// Spellings picked up from the user editing dictated text.
    Learned,
    /// A shared glossary pulled from the user's teams on a FnSpeak server.
    Team,
}

impl Source {
    fn as_str(self) -> &'static str {
        match self {
            Source::Project => "project",
            Source::Contact => "contact",
            Source::Calendar => "calendar",
            Source::User => "user",
            Source::Correction => "correction",
            Source::Learned => "learned",
            Source::Team => "team",
        }
    }

    /// Terms the user added or corrected themselves are the most trustworthy.
    fn default_weight(self) -> f64 {
        match self {
            Source::User | Source::Correction | Source::Learned | Source::Team => 2.0,
            Source::Contact | Source::Project => 1.0,
            Source::Calendar => 0.8,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Term {
    pub text: String,
    pub source: Source,
    pub weight: f64,
    pub hits: i64,
}

/// A proposed replacement of part of a transcript with a vocabulary term.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Suggestion {
    /// Byte range in the transcript that sounds like the term.
    pub start: usize,
    pub end: usize,
    pub heard: String,
    pub term: String,
    pub score: f64,
}

pub struct VocabIndex {
    conn: Connection,
    dm: DoubleMetaphone,
}

impl VocabIndex {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS terms (
                 id          INTEGER PRIMARY KEY,
                 term        TEXT NOT NULL,
                 normalized  TEXT NOT NULL,
                 phonetic    TEXT NOT NULL,
                 phonetic_alt TEXT NOT NULL,
                 source      TEXT NOT NULL,
                 weight      REAL NOT NULL,
                 hits        INTEGER NOT NULL DEFAULT 0,
                 last_used   INTEGER,
                 created_at  INTEGER NOT NULL,
                 UNIQUE (normalized, source)
             );
             CREATE INDEX IF NOT EXISTS terms_phonetic ON terms (phonetic);
             CREATE INDEX IF NOT EXISTS terms_phonetic_alt ON terms (phonetic_alt);
             -- What FnSpeak wrote (lowercase words) vs. what the user
             -- changed it to after insertion.
             CREATE TABLE IF NOT EXISTS corrections (
                 heard      TEXT NOT NULL,
                 corrected  TEXT NOT NULL,
                 count      INTEGER NOT NULL DEFAULT 1,
                 last_seen  INTEGER NOT NULL,
                 PRIMARY KEY (heard, corrected)
             );",
        )?;
        Ok(VocabIndex { conn, dm: DoubleMetaphone::new(None) })
    }

    /// Add terms from a source. Re-adding an existing term updates its spelling.
    pub fn add_terms<I, S>(&mut self, source: Source, terms: I) -> Result<usize>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let now = now();
        let tx = self.conn.transaction()?;
        let mut added = 0;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO terms (term, normalized, phonetic, phonetic_alt, source, weight, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT (normalized, source) DO UPDATE SET term = excluded.term",
            )?;
            for term in terms {
                let term = term.as_ref().trim();
                let norm = normalize(term);
                if norm.chars().count() < 3 {
                    continue;
                }
                let codes = self.dm.double_metaphone(&norm);
                stmt.execute(params![
                    term,
                    norm,
                    codes.primary(),
                    codes.alternate(),
                    source.as_str(),
                    source.default_weight(),
                    now
                ])?;
                added += 1;
            }
        }
        tx.commit()?;
        Ok(added)
    }

    /// Replace everything from one source, e.g. after re-indexing contacts.
    pub fn replace_source<I, S>(&mut self, source: Source, terms: I) -> Result<usize>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        self.conn.execute("DELETE FROM terms WHERE source = ?1", [source.as_str()])?;
        self.add_terms(source, terms)
    }

    pub fn len(&self) -> Result<usize> {
        let n: i64 = self.conn.query_row("SELECT COUNT(*) FROM terms", [], |r| r.get(0))?;
        Ok(n as usize)
    }

    pub fn is_empty(&self) -> Result<bool> {
        Ok(self.len()? == 0)
    }

    /// Find spans of `text` that sound like vocabulary terms but aren't spelled like them.
    pub fn suggest(&self, text: &str) -> Result<Vec<Suggestion>> {
        let words = word_spans(text);
        let mut candidates = Vec::new();
        let mut lookup = self.conn.prepare_cached(
            "SELECT term, normalized FROM terms
             WHERE phonetic = ?1 OR phonetic_alt = ?1 OR phonetic = ?2 OR phonetic_alt = ?2",
        )?;

        for n in 1..=MAX_WINDOW {
            for window in words.windows(n) {
                let (start, end) = (window[0].0, window[n - 1].1);
                let heard = &text[start..end];
                let norm = normalize(heard);
                if norm.chars().count() < 3 {
                    continue;
                }
                let codes = self.dm.double_metaphone(&norm);
                let rows = lookup.query_map(params![codes.primary(), codes.alternate()], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                })?;
                for row in rows {
                    let (term, term_norm) = row?;
                    if let Some(score) = score_match(heard, &norm, n, &term, &term_norm) {
                        candidates.push(Suggestion {
                            start,
                            end,
                            heard: heard.to_string(),
                            term,
                            score,
                        });
                    }
                }
            }
        }

        // Best first; drop anything overlapping a better match.
        candidates.sort_by(|a, b| b.score.total_cmp(&a.score).then((b.end - b.start).cmp(&(a.end - a.start))));
        let mut chosen: Vec<Suggestion> = Vec::new();
        for c in candidates {
            if chosen.iter().all(|s| c.end <= s.start || c.start >= s.end) {
                chosen.push(c);
            }
        }
        chosen.sort_by_key(|s| s.start);
        Ok(chosen)
    }

    /// Terms worth putting in front of the speech-to-text engine and the
    /// cleanup model: ones that sound like something in the transcript, ones
    /// that appear in the on-screen context, then the most used overall.
    pub fn relevant_terms(&self, context: &str, suggestions: &[Suggestion], limit: usize) -> Result<Vec<String>> {
        let mut out: Vec<String> = Vec::new();
        let push = |t: &str, out: &mut Vec<String>| {
            if out.len() < limit && !out.iter().any(|o| o == t) {
                out.push(t.to_string());
            }
        };
        for s in suggestions.iter().filter(|s| s.score >= HINT_SCORE) {
            push(&s.term, &mut out);
        }

        let context_norm = context.to_lowercase();
        let mut stmt = self.conn.prepare_cached("SELECT term, weight, hits FROM terms")?;
        let mut rows: Vec<(String, f64)> = stmt
            .query_map([], |r| {
                let (weight, hits): (f64, i64) = (r.get(1)?, r.get(2)?);
                Ok((r.get::<_, String>(0)?, weight * (1.0 + ((hits + 1) as f64).ln())))
            })?
            .collect::<std::result::Result<_, _>>()?;
        rows.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        let ranked: Vec<String> = rows.into_iter().map(|(t, _)| t).collect();

        if !context_norm.is_empty() {
            for term in ranked.iter().filter(|t| context_norm.contains(&t.to_lowercase())) {
                push(term, &mut out);
            }
        }
        for term in &ranked {
            push(term, &mut out);
        }
        Ok(out)
    }

    /// Record that terms made it into inserted text, so they rank higher next time.
    pub fn record_usage(&mut self, final_text: &str) -> Result<()> {
        let lower = final_text.to_lowercase();
        let terms: Vec<(i64, String)> = self
            .conn
            .prepare_cached("SELECT id, term FROM terms")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<std::result::Result<_, _>>()?;
        let now = now();
        for (id, term) in terms {
            if contains_word(&lower, &term.to_lowercase()) {
                self.conn.execute(
                    "UPDATE terms SET hits = hits + 1, last_used = ?2 WHERE id = ?1",
                    params![id, now],
                )?;
            }
        }
        Ok(())
    }

    /// Compare inserted text with the user's edit of it and remember any
    /// respellings. Returns the corrections that start applying as a result.
    pub fn learn_from_edit(&mut self, inserted: &str, final_text: &str) -> Result<Vec<LearnedCorrection>> {
        let mut learned = Vec::new();
        for c in corrections_from_edit(inserted, final_text) {
            if self.record_correction(&c.heard, &c.corrected)? {
                learned.push(c);
            }
        }
        Ok(learned)
    }

    /// Store a user correction. Once it's trusted (seen twice, or once if it's
    /// spelled like a name and isn't an everyday word) the corrected spelling
    /// joins the vocabulary. Returns true if this sighting made it trusted.
    pub fn record_correction(&mut self, heard: &str, corrected: &str) -> Result<bool> {
        let (heard, corrected) = (learn::heard_key(heard), corrected.trim());
        if heard.is_empty() || corrected.is_empty() {
            return Ok(false);
        }
        self.retarget_corrections(&heard, corrected)?;
        self.conn.execute(
            "INSERT INTO corrections (heard, corrected, last_seen) VALUES (?1, ?2, ?3)
             ON CONFLICT (heard, corrected) DO UPDATE SET count = count + 1, last_seen = excluded.last_seen",
            params![heard, corrected, now()],
        )?;
        let count: i64 = self.conn.query_row(
            "SELECT count FROM corrections WHERE heard = ?1 AND corrected = ?2",
            params![heard, corrected],
            |r| r.get(0),
        )?;
        if !is_trusted(count, corrected) {
            return Ok(false);
        }
        // A term the user already has from another source doesn't need a
        // learned copy.
        let known: bool = self.conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM terms WHERE normalized = ?1)",
            [normalize(corrected)],
            |r| r.get(0),
        )?;
        if !known {
            self.add_terms(Source::Learned, [corrected])?;
        }
        Ok(!is_trusted(count - 1, corrected))
    }

    /// The user is respelling a word FnSpeak only wrote because of an earlier
    /// correction ("whisper" became "Whispr", and now "Whispr" is being fixed
    /// to "Wispr"). Point the earlier correction at the new spelling, or it
    /// keeps producing the one the user just rejected.
    fn retarget_corrections(&mut self, heard: &str, corrected: &str) -> Result<()> {
        let rows: Vec<(String, String, i64)> = {
            let mut stmt = self.conn.prepare_cached("SELECT heard, corrected, count FROM corrections")?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<std::result::Result<_, _>>()?;
            rows
        };
        for (earlier, old, count) in rows {
            if earlier == heard || old == corrected || learn::heard_key(&old) != heard {
                continue;
            }
            self.conn.execute("DELETE FROM corrections WHERE heard = ?1 AND corrected = ?2", params![earlier, old])?;
            self.conn.execute(
                "INSERT INTO corrections (heard, corrected, count, last_seen) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT (heard, corrected) DO UPDATE SET count = count + excluded.count, last_seen = excluded.last_seen",
                params![earlier, corrected, count, now()],
            )?;
            self.conn.execute(
                "DELETE FROM terms WHERE normalized = ?1 AND source = ?2",
                params![normalize(&old), Source::Learned.as_str()],
            )?;
        }
        Ok(())
    }

    /// Trusted corrections to apply to new dictations, best supported first.
    /// Phrases made only of dictionary words are left to the phonetic matcher,
    /// which knows when not to touch them; a blanket "can" → "Kahn" would not.
    pub fn corrections(&self) -> Result<Vec<LearnedCorrection>> {
        let mut stmt =
            self.conn.prepare_cached("SELECT heard, corrected, count FROM corrections ORDER BY count DESC, last_seen DESC")?;
        let rows: Vec<(String, String, i64)> =
            stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<std::result::Result<_, _>>()?;
        let mut out: Vec<LearnedCorrection> = Vec::new();
        for (heard, corrected, count) in rows {
            if is_trusted(count, &corrected) && !learn::is_ordinary_phrase(&heard) && !out.iter().any(|c| c.heard == heard) {
                out.push(LearnedCorrection { heard, corrected });
            }
        }
        Ok(out)
    }

    /// Undo a learned correction, and the learned term if nothing else
    /// supports it.
    pub fn forget_correction(&mut self, heard: &str, corrected: &str) -> Result<bool> {
        let n = self.conn.execute(
            "DELETE FROM corrections WHERE heard = ?1 AND corrected = ?2",
            params![learn::heard_key(heard), corrected],
        )?;
        let still_used: bool =
            self.conn.query_row("SELECT EXISTS (SELECT 1 FROM corrections WHERE corrected = ?1)", [corrected], |r| r.get(0))?;
        if !still_used {
            self.conn.execute(
                "DELETE FROM terms WHERE normalized = ?1 AND source = ?2",
                params![normalize(corrected), Source::Learned.as_str()],
            )?;
        }
        Ok(n > 0)
    }

    pub fn terms(&self, source: Option<Source>) -> Result<Vec<Term>> {
        let mut stmt = self.conn.prepare(
            "SELECT term, source, weight, hits FROM terms WHERE ?1 IS NULL OR source = ?1 ORDER BY term",
        )?;
        let rows = stmt.query_map([source.map(Source::as_str)], |r| {
            let src: String = r.get(1)?;
            Ok(Term {
                text: r.get(0)?,
                source: parse_source(&src),
                weight: r.get(2)?,
                hits: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    pub fn remove_term(&mut self, term: &str) -> Result<bool> {
        let norm = normalize(term);
        let n = self.conn.execute("DELETE FROM terms WHERE normalized = ?1", [&norm])?;
        // Otherwise the corrections would keep writing the removed spelling.
        let targets: Vec<String> = self
            .conn
            .prepare_cached("SELECT DISTINCT corrected FROM corrections")?
            .query_map([], |r| r.get(0))?
            .collect::<std::result::Result<_, _>>()?;
        for corrected in targets.iter().filter(|c| normalize(c) == norm) {
            self.conn.execute("DELETE FROM corrections WHERE corrected = ?1", [corrected])?;
        }
        Ok(n > 0)
    }

    /// Distinct term spellings, keyed by normalized form. Used by the cleanup guardrail.
    pub fn spellings(&self) -> Result<HashMap<String, String>> {
        let mut stmt = self.conn.prepare_cached("SELECT normalized, term FROM terms")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }
}

/// Apply suggestions at or above `min_score` to `text`.
pub fn apply_suggestions(text: &str, suggestions: &[Suggestion], min_score: f64) -> String {
    let mut out = String::with_capacity(text.len());
    let mut cursor = 0;
    for s in suggestions.iter().filter(|s| s.score >= min_score) {
        if s.start < cursor {
            continue;
        }
        out.push_str(&text[cursor..s.start]);
        out.push_str(&s.term);
        cursor = s.end;
    }
    out.push_str(&text[cursor..]);
    out
}

/// Lowercase letters and digits only: "DoD Safe-Transfer" → "dodsafetransfer".
pub fn normalize(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

fn score_match(heard: &str, heard_norm: &str, words: usize, term: &str, term_norm: &str) -> Option<f64> {
    if heard_norm == term_norm {
        // Same letters. Only worth changing if the spelling actually differs
        // and the term carries capitalization or spacing the transcript lost.
        if heard == term {
            return None;
        }
        // An all-lowercase term only differs by case ("home" vs "Home"), which
        // isn't worth changing, unless the transcript split it into pieces
        // ("PG vector" → "pgvector").
        if !term.chars().any(char::is_uppercase) && words == 1 {
            return None;
        }
        return Some(if words > 1 || heard.chars().any(char::is_uppercase) { 0.97 } else { 0.93 });
    }
    let similarity = strsim::jaro_winkler(heard_norm, term_norm);
    // A sound-alike single word that's spelled very differently is usually a
    // real word ("can" vs "Kahn"), so demand more letter overlap for those.
    let floor = if words == 1 { 0.8 } else { 0.7 };
    if similarity < floor {
        return None;
    }
    Some(0.55 + 0.4 * similarity)
}

pub(crate) fn word_spans(text: &str) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut start = None;
    for (i, c) in text.char_indices() {
        let in_word = c.is_alphanumeric() || c == '\'' || c == '-';
        match (in_word, start) {
            (true, None) => start = Some(i),
            (false, Some(s)) => {
                spans.push((s, i));
                start = None;
            }
            _ => {}
        }
    }
    if let Some(s) = start {
        spans.push((s, text.len()));
    }
    spans
}

fn contains_word(haystack: &str, needle: &str) -> bool {
    haystack.match_indices(needle).any(|(i, _)| {
        let before = haystack[..i].chars().next_back();
        let after = haystack[i + needle.len()..].chars().next();
        !before.is_some_and(char::is_alphanumeric) && !after.is_some_and(char::is_alphanumeric)
    })
}

fn parse_source(s: &str) -> Source {
    match s {
        "project" => Source::Project,
        "contact" => Source::Contact,
        "calendar" => Source::Calendar,
        "correction" => Source::Correction,
        "learned" => Source::Learned,
        "team" => Source::Team,
        _ => Source::User,
    }
}

/// Seen twice, or once when it's spelled like a name and isn't an everyday
/// word: nobody retypes "Kinju" by accident.
fn is_trusted(count: i64, corrected: &str) -> bool {
    count >= 2 || (count >= 1 && learn::looks_like_name(corrected) && !learn::is_common_phrase(corrected))
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index() -> VocabIndex {
        let mut v = VocabIndex::in_memory().unwrap();
        v.add_terms(Source::Project, ["Kinju", "Virescent", "DoDSafeTransfer", "home", "Mango Tuesday"])
            .unwrap();
        v.add_terms(Source::Contact, ["Priya Raman", "Siobhan"]).unwrap();
        v
    }

    #[test]
    fn merges_split_names() {
        let v = index();
        let s = v.suggest("push the kin ju build").unwrap();
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].heard, "kin ju");
        assert_eq!(s[0].term, "Kinju");
        assert!(s[0].score >= AUTO_APPLY_SCORE);
        assert_eq!(apply_suggestions("push the kin ju build", &s, AUTO_APPLY_SCORE), "push the Kinju build");
    }

    #[test]
    fn fixes_sound_alike_spelling() {
        let v = index();
        let s = v.suggest("the viressent repo").unwrap();
        assert_eq!(s.first().map(|s| s.term.as_str()), Some("Virescent"));
    }

    #[test]
    fn restores_identifier_casing() {
        let v = index();
        let text = "deploy dod safe transfer tonight";
        let s = v.suggest(text).unwrap();
        assert_eq!(apply_suggestions(text, &s, AUTO_APPLY_SCORE), "deploy DoDSafeTransfer tonight");
    }

    #[test]
    fn joins_split_lowercase_terms() {
        let mut v = index();
        v.add_terms(Source::User, ["pgvector"]).unwrap();
        let text = "review the PG vector migration";
        let s = v.suggest(text).unwrap();
        assert_eq!(apply_suggestions(text, &s, AUTO_APPLY_SCORE), "review the pgvector migration");
    }

    #[test]
    fn team_terms_round_trip_and_replace_only_their_source() {
        let mut v = index();
        v.replace_source(Source::Team, ["Kubernetes", "FnSpeak Cloud"]).unwrap();
        v.replace_source(Source::Team, ["FnSpeak Cloud"]).unwrap();
        let team: Vec<String> = v.terms(Some(Source::Team)).unwrap().into_iter().map(|t| t.text).collect();
        assert_eq!(team, vec!["FnSpeak Cloud".to_string()]);
        assert!(v.terms(None).unwrap().iter().any(|t| t.text == "Kinju" && t.source == Source::Project));
    }

    #[test]
    fn leaves_common_words_alone() {
        let v = index();
        assert!(v.suggest("I'm heading home now").unwrap().is_empty());
        assert!(v.suggest("you can do that").unwrap().is_empty());
    }

    #[test]
    fn relevant_terms_prefers_matches_and_context() {
        let v = index();
        let s = v.suggest("ask priya raman").unwrap();
        let terms = v.relevant_terms("Re: Siobhan's notes", &s, 3).unwrap();
        assert_eq!(terms[0], "Priya Raman");
        assert_eq!(terms[1], "Siobhan");
        assert_eq!(terms.len(), 3);
    }

    #[test]
    fn corrections_promote_after_two() {
        let mut v = VocabIndex::in_memory().unwrap();
        assert!(!v.record_correction("pg vector", "pgvector").unwrap());
        assert!(v.terms(Some(Source::Learned)).unwrap().is_empty());
        assert!(v.corrections().unwrap().is_empty());
        assert!(v.record_correction("PG vector", "pgvector").unwrap());
        assert_eq!(v.terms(Some(Source::Learned)).unwrap()[0].text, "pgvector");
        assert_eq!(v.corrections().unwrap()[0].heard, "pg vector");
    }

    #[test]
    fn names_promote_at_once() {
        let mut v = VocabIndex::in_memory().unwrap();
        let learned = v.learn_from_edit("Push the kin ju build.", "Push the Kinju build.").unwrap();
        assert_eq!(learned, [LearnedCorrection { heard: "kin ju".into(), corrected: "Kinju".into() }]);
        assert_eq!(v.terms(None).unwrap()[0].source, Source::Learned);
        // Already trusted: seeing it again isn't news.
        assert!(v.learn_from_edit("Push the kin ju build.", "Push the Kinju build.").unwrap().is_empty());
    }

    #[test]
    fn learned_terms_reach_speech_hints() {
        let mut v = index();
        v.learn_from_edit("Ask Priya about it.", "Ask Pria about it.").unwrap();
        assert!(v.relevant_terms("", &[], 40).unwrap().contains(&"Pria".to_string()));
    }

    #[test]
    fn known_terms_are_not_duplicated() {
        let mut v = index();
        assert!(v.record_correction("kenju", "Kinju").unwrap());
        assert!(v.terms(Some(Source::Learned)).unwrap().is_empty());
        assert_eq!(v.corrections().unwrap().len(), 1);
    }

    #[test]
    fn common_heard_words_are_not_blanket_replaced() {
        let mut v = VocabIndex::in_memory().unwrap();
        v.record_correction("can", "Kahn").unwrap();
        v.record_correction("can", "Kahn").unwrap();
        assert!(v.corrections().unwrap().is_empty());
        assert_eq!(v.terms(Some(Source::Learned)).unwrap()[0].text, "Kahn");
    }

    #[test]
    fn forgetting_removes_the_learned_term() {
        let mut v = VocabIndex::in_memory().unwrap();
        v.learn_from_edit("Kenju is live.", "Kinju is live.").unwrap();
        v.record_correction("kin ju", "Kinju").unwrap();
        assert!(v.forget_correction("kenju", "Kinju").unwrap());
        assert_eq!(v.terms(None).unwrap().len(), 1, "still backed by kin ju");
        v.forget_correction("kin ju", "Kinju").unwrap();
        assert!(v.terms(None).unwrap().is_empty());
        assert!(v.corrections().unwrap().is_empty());
    }

    #[test]
    fn a_second_fix_retargets_the_first() {
        let mut v = VocabIndex::in_memory().unwrap();
        // "kenju" was fixed to "Kenjoo", then "Kenjoo" itself to "Kinju".
        assert!(v.record_correction("kenju", "Kenjoo").unwrap());
        assert!(v.record_correction("Kenjoo", "Kinju").unwrap());
        let rules = v.corrections().unwrap();
        assert!(rules.contains(&LearnedCorrection { heard: "kenju".into(), corrected: "Kinju".into() }));
        assert!(!rules.iter().any(|c| c.corrected == "Kenjoo"));
        // The rejected spelling doesn't linger in the vocabulary either.
        let terms: Vec<String> = v.terms(None).unwrap().into_iter().map(|t| t.text).collect();
        assert!(terms.contains(&"Kinju".to_string()) && !terms.contains(&"Kenjoo".to_string()));
    }

    #[test]
    fn a_dictionary_word_is_never_rewritten_wholesale() {
        // Only where the system word list exists (macOS).
        if !std::path::Path::new("/usr/share/dict/words").exists() {
            return;
        }
        let mut v = VocabIndex::in_memory().unwrap();
        v.record_correction("whisper", "Wispr").unwrap();
        v.record_correction("kenju", "Kinju").unwrap();
        let rules = v.corrections().unwrap();
        assert!(!rules.iter().any(|c| c.heard == "whisper"));
        assert!(rules.iter().any(|c| c.heard == "kenju"));
        // The spelling is still learned, for the speech model and the phonetic matcher.
        assert!(v.terms(None).unwrap().iter().any(|t| t.text == "Wispr"));
    }

    #[test]
    fn removing_a_term_drops_its_corrections() {
        let mut v = VocabIndex::in_memory().unwrap();
        v.learn_from_edit("Kenju is live.", "Kinju is live.").unwrap();
        assert!(v.remove_term("Kinju").unwrap());
        assert!(v.corrections().unwrap().is_empty());
    }

    #[test]
    fn usage_increments_hits() {
        let mut v = index();
        v.record_usage("Shipped Kinju today").unwrap();
        let kinju = v.terms(Some(Source::Project)).unwrap().into_iter().find(|t| t.text == "Kinju").unwrap();
        assert_eq!(kinju.hits, 1);
    }
}
