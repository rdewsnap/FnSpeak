//! Snippets: say a trigger phrase, get a saved block of text.
//!
//! Personal snippets are the user's own. Team snippets are pulled from a
//! FnSpeak server and replaced wholesale on every sync. Triggers are
//! matched on whole words anywhere in a dictation, so they have to be
//! distinctive: see `check_trigger`.

pub mod matcher;

pub use crate::vocab::learn::heard_key as trigger_key;
pub use matcher::{expand, find, Match};

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
