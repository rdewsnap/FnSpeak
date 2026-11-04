use crate::store::Store;
use rmcp::{
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{
        Implementation, ListResourceTemplatesResult, ListResourcesResult, PaginatedRequestParams,
        ReadResourceRequestParams, ReadResourceResponse, ReadResourceResult, Resource,
        ResourceContents, ResourceTemplate, ServerCapabilities, ServerConfig,
    },
    service::RequestContext,
    tool, tool_handler, tool_router, ErrorData, RoleServer, ServerHandler,
};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

const INSTRUCTIONS: &str = "This server exposes the user's private FnSpeak data, stored locally on their Mac and never sent anywhere else: \
their notes, meeting transcripts with summaries and action items, and a history of their voice dictations. \
Treat it as personal context to help answer questions about what they said, decided or wrote. \
Use `search` to find things, then fetch full records with `get_note` or `get_meeting`. \
Timestamps are Unix seconds with UTC ISO equivalents, and the data is read-only unless a `create_note` tool is offered.";

#[derive(Clone)]
pub struct FnSpeakServer {
    store: Arc<Store>,
    tool_router: ToolRouter<Self>,
}

#[derive(Deserialize, JsonSchema)]
pub struct SearchArgs {
    /// Words to look for across notes, meeting transcripts and dictations.
    pub query: String,
    /// Maximum hits to return (default 20).
    pub limit: Option<usize>,
}

#[derive(Deserialize, JsonSchema)]
pub struct ListNotesArgs {
    /// Maximum notes to return (default 50).
    pub limit: Option<usize>,
    /// Only return pinned notes (default false).
    pub pinned_only: Option<bool>,
}

#[derive(Deserialize, JsonSchema)]
pub struct IdArgs {
    pub id: i64,
}

#[derive(Deserialize, JsonSchema)]
pub struct ListMeetingsArgs {
    /// Only meetings that started at or after this Unix time (seconds).
    pub since_unix: Option<i64>,
    /// Maximum meetings to return, newest first (default 20).
    pub limit: Option<usize>,
}

#[derive(Deserialize, JsonSchema)]
pub struct GetMeetingArgs {
    pub id: i64,
    /// Include the full transcript (default false; transcripts can be long).
    pub include_transcript: Option<bool>,
}

#[derive(Deserialize, JsonSchema)]
pub struct ActionItemsArgs {
    /// Skip items already checked off (default true).
    pub open_only: Option<bool>,
}

#[derive(Deserialize, JsonSchema)]
pub struct DictationsArgs {
    /// Maximum dictations to return, newest first (default 20).
    pub limit: Option<usize>,
    /// Only dictations made in this app, e.g. com.apple.mail.
    pub app_id: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
pub struct CreateNoteArgs {
    pub title: String,
    /// Note body in Markdown.
    pub body: String,
}

#[derive(Serialize)]
struct Listing<T: Serialize> {
    count: usize,
    items: Vec<T>,
    #[serde(skip_serializing_if = "Option::is_none")]
    note: Option<&'static str>,
}

const NO_NOTES: &str = "No notes database yet. FnSpeak creates it when you record a meeting or save a note.";
const NO_HISTORY: &str = "No dictation history yet. FnSpeak creates it after your first dictation.";

fn json<T: Serialize>(v: &T) -> Result<String, String> {
    serde_json::to_string_pretty(v).map_err(|e| e.to_string())
}

fn listing<T: Serialize>(items: Vec<T>, missing: bool, note: &'static str) -> Result<String, String> {
    json(&Listing { count: items.len(), items, note: missing.then_some(note) })
}

fn err(e: anyhow::Error) -> String {
    format!("{e:#}")
}

fn not_found(what: &str, id: i64) -> String {
    format!("No {what} with id {id}")
}

#[tool_router]
impl FnSpeakServer {
    pub fn new(store: Store, allow_write: bool) -> Self {
        let mut tool_router = Self::tool_router();
        if !allow_write {
            tool_router.remove_route("create_note");
        }
        FnSpeakServer { store: Arc::new(store), tool_router }
    }

    #[tool(
        description = "Full-text search across the user's notes, meeting transcript segments and dictations. Returns typed hits (note, meeting_segment, dictation) with snippets and ids to fetch in full.",
        annotations(read_only_hint = true)
    )]
    pub fn search(&self, Parameters(a): Parameters<SearchArgs>) -> Result<String, String> {
        let hits = self.store.search(&a.query, a.limit.unwrap_or(20)).map_err(err)?;
        let missing = self.store.notes_missing() && self.store.history_missing();
        listing(hits, missing, "No FnSpeak data yet. Notes, meetings and dictations appear here once you use the app.")
    }

    #[tool(
        description = "List the user's notes, pinned first then most recently updated, with a short preview of each.",
        annotations(read_only_hint = true)
    )]
    pub fn list_notes(&self, Parameters(a): Parameters<ListNotesArgs>) -> Result<String, String> {
        let notes = self.store.list_notes(a.limit.unwrap_or(50), a.pinned_only.unwrap_or(false)).map_err(err)?;
        listing(notes, self.store.notes_missing(), NO_NOTES)
    }

    #[tool(description = "Get one note in full, including its Markdown body.", annotations(read_only_hint = true))]
    pub fn get_note(&self, Parameters(a): Parameters<IdArgs>) -> Result<String, String> {
        match self.store.get_note(a.id).map_err(err)? {
            Some(n) => json(&n),
            None => Err(not_found("note", a.id)),
        }
    }

    #[tool(
        description = "List recorded meetings, newest first, with title, time, participants and whether a summary exists.",
        annotations(read_only_hint = true)
    )]
    pub fn list_meetings(&self, Parameters(a): Parameters<ListMeetingsArgs>) -> Result<String, String> {
        let meetings = self.store.list_meetings(a.since_unix, a.limit.unwrap_or(20)).map_err(err)?;
        listing(meetings, self.store.notes_missing(), NO_NOTES)
    }

    #[tool(
        description = "Get one meeting: metadata, summary and action items, plus the speaker-labelled transcript when include_transcript is true.",
        annotations(read_only_hint = true)
    )]
    pub fn get_meeting(&self, Parameters(a): Parameters<GetMeetingArgs>) -> Result<String, String> {
        match self.store.get_meeting(a.id, a.include_transcript.unwrap_or(false)).map_err(err)? {
            Some(m) => json(&m),
            None => Err(not_found("meeting", a.id)),
        }
    }

    #[tool(description = "Get just the Markdown summary of a meeting.", annotations(read_only_hint = true))]
    pub fn get_meeting_summary(&self, Parameters(a): Parameters<IdArgs>) -> Result<String, String> {
        match self.store.get_meeting_summary(a.id).map_err(err)? {
            Some(Some(s)) => Ok(s),
            Some(None) => Ok("This meeting has no summary yet.".into()),
            None => Err(not_found("meeting", a.id)),
        }
    }

    #[tool(
        description = "List action items across all meetings, newest meeting first. Open items only by default.",
        annotations(read_only_hint = true)
    )]
    pub fn list_action_items(&self, Parameters(a): Parameters<ActionItemsArgs>) -> Result<String, String> {
        let items = self.store.list_action_items(a.open_only.unwrap_or(true)).map_err(err)?;
        listing(items, self.store.notes_missing(), NO_NOTES)
    }

    #[tool(
        description = "Recent voice dictations, newest first, with the cleaned text and the raw transcript. Optionally filter by app bundle id.",
        annotations(read_only_hint = true)
    )]
    pub fn recent_dictations(&self, Parameters(a): Parameters<DictationsArgs>) -> Result<String, String> {
        let items = self.store.recent_dictations(a.limit.unwrap_or(20), a.app_id.as_deref()).map_err(err)?;
        listing(items, self.store.history_missing(), NO_HISTORY)
    }

    #[tool(
        description = "Export a meeting as one Markdown document: title, date, participants, summary, action items and the full transcript with [hh:mm:ss] Speaker: lines.",
        annotations(read_only_hint = true)
    )]
    pub fn export_meeting_markdown(&self, Parameters(a): Parameters<IdArgs>) -> Result<String, String> {
        self.store.export_meeting_markdown(a.id).map_err(err)?.ok_or_else(|| not_found("meeting", a.id))
    }

    #[tool(description = "Save a new Markdown note to the user's FnSpeak notes.")]
    pub fn create_note(&self, Parameters(a): Parameters<CreateNoteArgs>) -> Result<String, String> {
        let id = self.store.create_note(&a.title, &a.body).map_err(err)?;
        Ok(format!("Created note {id}"))
    }

    fn resource_text(&self, uri: &str) -> Result<Option<String>, ErrorData> {
        let internal = |e: anyhow::Error| ErrorData::internal_error(format!("{e:#}"), None);
        if let Some(id) = uri.strip_prefix("fnspeak://notes/").and_then(|s| s.parse().ok()) {
            return self.store.note_markdown(id).map_err(internal);
        }
        if let Some(id) = uri.strip_prefix("fnspeak://meetings/").and_then(|s| s.parse().ok()) {
            return self.store.export_meeting_markdown(id).map_err(internal);
        }
        Ok(None)
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for FnSpeakServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().enable_resources().build())
            .with_server_info(Implementation::new("fnspeak-mcp", env!("CARGO_PKG_VERSION")))
            .with_instructions(INSTRUCTIONS)
    }

    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, ErrorData> {
        let internal = |e: anyhow::Error| ErrorData::internal_error(format!("{e:#}"), None);
        let mut resources = vec![];
        for n in self.store.list_notes(50, false).map_err(internal)? {
            resources.push(
                Resource::new(format!("fnspeak://notes/{}", n.id), format!("Note: {}", n.title))
                    .with_mime_type("text/markdown"),
            );
        }
        for m in self.store.list_meetings(None, 50).map_err(internal)? {
            resources.push(
                Resource::new(format!("fnspeak://meetings/{}", m.id), format!("Meeting: {}", m.title))
                    .with_description(m.started_at_iso)
                    .with_mime_type("text/markdown"),
            );
        }
        Ok(ListResourcesResult::with_all_items(resources))
    }

    async fn list_resource_templates(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourceTemplatesResult, ErrorData> {
        Ok(ListResourceTemplatesResult::with_all_items(vec![
            ResourceTemplate::new("fnspeak://notes/{id}", "note").with_mime_type("text/markdown"),
            ResourceTemplate::new("fnspeak://meetings/{id}", "meeting")
                .with_description("Meeting exported as Markdown, with transcript")
                .with_mime_type("text/markdown"),
        ]))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, ErrorData> {
        match self.resource_text(&request.uri)? {
            Some(text) => Ok(ReadResourceResult::new(vec![ResourceContents::TextResourceContents {
                uri: request.uri,
                mime_type: Some("text/markdown".into()),
                text,
                meta: None,
            }])
            .into()),
            None => Err(ErrorData::resource_not_found(format!("No resource at {}", request.uri), None)),
        }
    }
}
