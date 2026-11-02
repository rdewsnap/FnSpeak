//! Model Context Protocol endpoint at `/mcp` (Streamable HTTP, stateless),
//! so AI assistants can search and read a user's notes, meetings and
//! summaries. Authenticated with the same API tokens as the REST API, and
//! scoped to exactly what that user can see.

use axum::extract::{Request, State};
use axum::http::request::Parts;
use axum::http::{header, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use rmcp::handler::server::tool::Extension;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{
    CallToolResult, ContentBlock, Implementation, ListResourceTemplatesResult, ListResourcesResult,
    PaginatedRequestParams, ReadResourceRequestParams, ReadResourceResponse, ReadResourceResult, Resource,
    ResourceContents, ResourceTemplate, ServerCapabilities, ServerConfig,
};
use rmcp::service::RequestContext;
use rmcp::transport::streamable_http_server::session::never::NeverSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use rmcp::{tool, tool_handler, tool_router, ErrorData as McpError, RoleServer, ServerHandler};
use serde::Deserialize;
use serde_json::{json, Value};
use std::fmt::Write;
use std::sync::Arc;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use crate::auth::AuthUser;
use crate::config::host_of;
use crate::db::now_ms;
use crate::error::ApiError;
use crate::store::{self, Meeting, Note, NoteIn};
use crate::AppState;

const NOTE_URI: &str = "flowstate://notes/";
const MEETING_URI: &str = "flowstate://meetings/";

/// The tower service mounted at `/mcp`. Requests reach it only after
/// [`require_token`] has put the caller in the request extensions.
pub fn service(state: AppState) -> StreamableHttpService<FlowstateMcp, NeverSessionManager> {
    let mut hosts = vec![host_of(&state.config.base_url), "localhost".into(), "127.0.0.1".into()];
    hosts.dedup();
    let config = StreamableHttpServerConfig::default()
        .with_legacy_session_mode(false)
        .with_json_response(true)
        .with_allowed_hosts(hosts);
    StreamableHttpService::new(
        move || Ok(FlowstateMcp { state: state.clone() }),
        Arc::new(NeverSessionManager::default()),
        config,
    )
}

/// Middleware for `/mcp`: resolve the bearer token or answer 401.
pub async fn require_token(State(state): State<AppState>, mut req: Request, next: Next) -> Response {
    match AuthUser::from_headers(&state, req.headers()).await {
        Ok(user) => {
            req.extensions_mut().insert(user);
            next.run(req).await
        }
        Err(ApiError::Unauthorized) => (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, "Bearer")],
            axum::Json(json!({ "error": { "code": "unauthorized", "message": "send Authorization: Bearer <Flowstate API token>" } })),
        )
            .into_response(),
        Err(e) => e.into_response(),
    }
}

#[derive(Clone)]
pub struct FlowstateMcp {
    state: AppState,
}

fn caller(parts: &Parts) -> Result<AuthUser, McpError> {
    parts
        .extensions
        .get::<AuthUser>()
        .cloned()
        .ok_or_else(|| McpError::invalid_request("not authenticated", None))
}

fn caller_from(ctx: &RequestContext<RoleServer>) -> Result<AuthUser, McpError> {
    ctx.extensions.get::<Parts>().ok_or_else(|| McpError::invalid_request("not authenticated", None)).and_then(caller)
}

fn internal(e: ApiError) -> McpError {
    tracing::error!(error = %e, "mcp request failed");
    McpError::internal_error("internal error", None)
}

fn json_result(v: Value) -> Result<CallToolResult, McpError> {
    Ok(CallToolResult::success(vec![ContentBlock::text(
        serde_json::to_string_pretty(&v).unwrap_or_default(),
    )]))
}

fn not_found(what: &str) -> Result<CallToolResult, McpError> {
    Ok(CallToolResult::error(vec![ContentBlock::text(format!("No {what} with that id, or you can't see it."))]))
}

pub fn iso(ms: i64) -> String {
    OffsetDateTime::from_unix_timestamp_nanos(ms as i128 * 1_000_000)
        .ok()
        .and_then(|t| t.format(&Rfc3339).ok())
        .unwrap_or_default()
}

/// Accepts Unix milliseconds, an RFC 3339 timestamp or a `YYYY-MM-DD` date.
fn parse_since(s: &str) -> Option<i64> {
    let s = s.trim();
    if let Ok(ms) = s.parse::<i64>() {
        return Some(ms);
    }
    if let Ok(t) = OffsetDateTime::parse(s, &Rfc3339) {
        return Some((t.unix_timestamp_nanos() / 1_000_000) as i64);
    }
    let t = OffsetDateTime::parse(&format!("{s}T00:00:00Z"), &Rfc3339).ok()?;
    Some((t.unix_timestamp_nanos() / 1_000_000) as i64)
}

fn note_json(n: &Note) -> Value {
    json!({
        "id": n.id, "uri": format!("{NOTE_URI}{}", n.id), "title": n.title, "body_md": n.body_md,
        "source": n.source, "meeting_id": n.meeting_id, "tags": parse_list(&n.tags_json), "pinned": n.pinned,
        "shared_with_team": n.visibility == "team", "created_at": iso(n.created_at), "updated_at": iso(n.updated_at),
    })
}

fn meeting_json(m: &Meeting) -> Value {
    let mut v = json!({
        "id": m.id, "uri": format!("{MEETING_URI}{}", m.id), "title": m.title, "status": m.status,
        "started_at": iso(m.started_at), "ended_at": m.ended_at.map(iso),
        "participants": parse_list(&m.participants_json), "summary_md": m.summary_md,
        "action_items": parse_list(&m.action_items_json), "shared_with_team": m.visibility == "team",
    });
    if let Some(t) = &m.raw_transcript_md {
        v["transcript_md"] = json!(t);
    }
    if let Some(segments) = &m.segments {
        v["segments"] = json!(segments);
    }
    v
}

fn parse_list(s: &str) -> Value {
    serde_json::from_str::<Value>(s).unwrap_or_else(|_| json!([]))
}

/// Action items are free-form JSON from the app; anything marked done,
/// completed or closed counts as finished.
fn is_done(item: &Value) -> bool {
    let flag = |k: &str| match item.get(k) {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_i64() == Some(1),
        _ => false,
    };
    let status = item.get("status").and_then(Value::as_str).unwrap_or("").to_lowercase();
    flag("done") || flag("completed") || matches!(status.as_str(), "done" | "completed" | "closed")
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct SearchArgs {
    /// Words to look for in titles, note bodies, meeting summaries and transcripts.
    pub query: String,
    /// Maximum results (default 10, at most 50).
    pub limit: Option<i64>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct IdArgs {
    /// The note or meeting id.
    pub id: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ListMeetingsArgs {
    /// Only meetings that started at or after this time: a date (2026-10-01), an RFC 3339 timestamp, or Unix milliseconds.
    pub since: Option<String>,
    /// Maximum meetings (default 20, at most 100).
    pub limit: Option<i64>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct GetMeetingArgs {
    pub id: String,
    /// Include the full transcript and timed segments (can be long).
    pub include_transcript: Option<bool>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ActionItemsArgs {
    /// Only items not marked done (default true).
    pub open_only: Option<bool>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct CreateNoteArgs {
    pub title: String,
    /// Markdown body.
    pub body: String,
}

#[tool_router]
impl FlowstateMcp {
    #[tool(description = "Full-text search across the user's Flowstate notes and meetings (titles, note bodies, summaries and transcripts), including items teammates shared with them. Returns ids, titles and matching snippets.")]
    async fn search_notes(
        &self,
        Parameters(args): Parameters<SearchArgs>,
        Extension(parts): Extension<Parts>,
    ) -> Result<CallToolResult, McpError> {
        let user = caller(&parts)?;
        let hits = store::search(&self.state.db, &user.user_id, &args.query, args.limit.unwrap_or(10).min(50))
            .await
            .map_err(internal)?;
        let results: Vec<Value> = hits
            .iter()
            .map(|h| {
                let uri = if h.kind == "note" { NOTE_URI } else { MEETING_URI };
                json!({ "kind": h.kind, "id": h.id, "uri": format!("{uri}{}", h.id), "title": h.title,
                        "snippet": h.snippet, "date": iso(h.at) })
            })
            .collect();
        json_result(json!({ "results": results }))
    }

    #[tool(description = "Get one Flowstate note by id, with its full Markdown body.")]
    async fn get_note(
        &self,
        Parameters(args): Parameters<IdArgs>,
        Extension(parts): Extension<Parts>,
    ) -> Result<CallToolResult, McpError> {
        let user = caller(&parts)?;
        match store::get_note(&self.state.db, &user.user_id, &args.id).await.map_err(internal)? {
            Some(n) if !n.deleted => json_result(note_json(&n)),
            _ => not_found("note"),
        }
    }

    #[tool(description = "List the user's recorded meetings, newest first, with titles, times, participants and summaries.")]
    async fn list_meetings(
        &self,
        Parameters(args): Parameters<ListMeetingsArgs>,
        Extension(parts): Extension<Parts>,
    ) -> Result<CallToolResult, McpError> {
        let user = caller(&parts)?;
        let since = match args.since.as_deref() {
            Some(s) => match parse_since(s) {
                Some(ms) => Some(ms),
                None => {
                    return Ok(CallToolResult::error(vec![ContentBlock::text(
                        "since must be a date like 2026-10-01, an RFC 3339 timestamp or Unix milliseconds",
                    )]))
                }
            },
            None => None,
        };
        let meetings = store::list_meetings(&self.state.db, &user.user_id, since, args.limit.unwrap_or(20).min(100))
            .await
            .map_err(internal)?;
        json_result(json!({ "meetings": meetings.iter().map(meeting_json).collect::<Vec<_>>() }))
    }

    #[tool(description = "Get one meeting by id: summary, action items and participants, and optionally the full transcript.")]
    async fn get_meeting(
        &self,
        Parameters(args): Parameters<GetMeetingArgs>,
        Extension(parts): Extension<Parts>,
    ) -> Result<CallToolResult, McpError> {
        let user = caller(&parts)?;
        let full = args.include_transcript.unwrap_or(false);
        match store::get_meeting(&self.state.db, &user.user_id, &args.id, full, full).await.map_err(internal)? {
            Some(m) if !m.deleted => json_result(meeting_json(&m)),
            _ => not_found("meeting"),
        }
    }

    #[tool(description = "Get just the Markdown summary and action items of a meeting.")]
    async fn get_meeting_summary(
        &self,
        Parameters(args): Parameters<IdArgs>,
        Extension(parts): Extension<Parts>,
    ) -> Result<CallToolResult, McpError> {
        let user = caller(&parts)?;
        match store::get_meeting(&self.state.db, &user.user_id, &args.id, false, false).await.map_err(internal)? {
            Some(m) if !m.deleted => json_result(json!({
                "id": m.id, "title": m.title, "started_at": iso(m.started_at),
                "summary_md": m.summary_md, "action_items": parse_list(&m.action_items_json),
            })),
            _ => not_found("meeting"),
        }
    }

    #[tool(description = "List action items from the user's recent meetings (the latest 200), with the meeting each came from.")]
    async fn list_action_items(
        &self,
        Parameters(args): Parameters<ActionItemsArgs>,
        Extension(parts): Extension<Parts>,
    ) -> Result<CallToolResult, McpError> {
        let user = caller(&parts)?;
        let open_only = args.open_only.unwrap_or(true);
        let meetings = store::list_meetings(&self.state.db, &user.user_id, None, 200).await.map_err(internal)?;
        let mut items = Vec::new();
        for m in &meetings {
            let Value::Array(list) = parse_list(&m.action_items_json) else { continue };
            for item in list.into_iter().filter(|i| !(open_only && is_done(i))) {
                items.push(json!({
                    "item": item, "meeting_id": m.id, "meeting_title": m.title, "meeting_started_at": iso(m.started_at),
                }));
            }
        }
        json_result(json!({ "action_items": items }))
    }

    #[tool(description = "Create a new private note in the user's Flowstate. It syncs to their devices.")]
    async fn create_note(
        &self,
        Parameters(args): Parameters<CreateNoteArgs>,
        Extension(parts): Extension<Parts>,
    ) -> Result<CallToolResult, McpError> {
        let user = caller(&parts)?;
        let id = crate::db::new_id();
        let now = now_ms();
        let note = NoteIn {
            id: id.clone(),
            created_at: Some(now),
            updated_at: now,
            title: args.title,
            body_md: args.body,
            source: "mcp".into(),
            ..Default::default()
        };
        match store::upsert_note(&self.state.db, &user.user_id, note).await {
            Ok(_) => json_result(json!({ "id": id, "uri": format!("{NOTE_URI}{id}") })),
            Err(ApiError::BadRequest(msg)) => Ok(CallToolResult::error(vec![ContentBlock::text(msg)])),
            Err(e) => Err(internal(e)),
        }
    }
}

#[tool_handler]
impl ServerHandler for FlowstateMcp {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().enable_resources().build())
            .with_server_info(Implementation::new("flowstate", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "Flowstate holds the user's dictated notes and recorded meetings (summaries, action items and \
                 transcripts), plus anything teammates shared with them. Use search_notes to find things, then \
                 get_note or get_meeting for the full text.",
            )
    }

    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        ctx: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, McpError> {
        let user = caller_from(&ctx)?;
        let db = &self.state.db;
        let notes = store::list_notes(db, &user.user_id, 50, 0).await.map_err(internal)?;
        let meetings = store::list_meetings(db, &user.user_id, None, 50).await.map_err(internal)?;
        let resources = notes
            .iter()
            .map(|n| {
                Resource::new(format!("{NOTE_URI}{}", n.id), title_or(&n.title, "Untitled note"))
                    .with_mime_type("text/markdown")
            })
            .chain(meetings.iter().map(|m| {
                Resource::new(format!("{MEETING_URI}{}", m.id), title_or(&m.title, "Untitled meeting"))
                    .with_description(format!("Meeting on {}", iso(m.started_at)))
                    .with_mime_type("text/markdown")
            }))
            .collect();
        Ok(ListResourcesResult::with_all_items(resources))
    }

    async fn list_resource_templates(
        &self,
        _request: Option<PaginatedRequestParams>,
        _ctx: RequestContext<RoleServer>,
    ) -> Result<ListResourceTemplatesResult, McpError> {
        Ok(ListResourceTemplatesResult::with_all_items(vec![
            ResourceTemplate::new(format!("{NOTE_URI}{{id}}"), "note").with_mime_type("text/markdown"),
            ResourceTemplate::new(format!("{MEETING_URI}{{id}}"), "meeting").with_mime_type("text/markdown"),
        ]))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        ctx: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, McpError> {
        let user = caller_from(&ctx)?;
        let uri = request.uri;
        let db = &self.state.db;
        let text = if let Some(id) = uri.strip_prefix(NOTE_URI) {
            store::get_note(db, &user.user_id, id).await.map_err(internal)?.filter(|n| !n.deleted).map(|n| note_markdown(&n))
        } else if let Some(id) = uri.strip_prefix(MEETING_URI) {
            store::get_meeting(db, &user.user_id, id, true, false)
                .await
                .map_err(internal)?
                .filter(|m| !m.deleted)
                .map(|m| meeting_markdown(&m))
        } else {
            None
        };
        let text = text.ok_or_else(|| McpError::resource_not_found(format!("no resource at {uri}"), None))?;
        Ok(ReadResourceResult::new(vec![ResourceContents::text(text, uri)]).into())
    }
}

fn title_or(title: &str, fallback: &str) -> String {
    if title.trim().is_empty() { fallback.to_string() } else { title.to_string() }
}

fn note_markdown(n: &Note) -> String {
    format!("# {}\n\n{}\n", title_or(&n.title, "Untitled note"), n.body_md)
}

fn meeting_markdown(m: &Meeting) -> String {
    let mut out = format!("# {}\n\n", title_or(&m.title, "Untitled meeting"));
    let _ = writeln!(out, "Started: {}", iso(m.started_at));
    if let Value::Array(people) = parse_list(&m.participants_json) {
        if !people.is_empty() {
            let names: Vec<String> =
                people.iter().map(|p| p.as_str().map(str::to_string).unwrap_or_else(|| p.to_string())).collect();
            let _ = writeln!(out, "Participants: {}", names.join(", "));
        }
    }
    if !m.summary_md.trim().is_empty() {
        let _ = write!(out, "\n## Summary\n\n{}\n", m.summary_md.trim());
    }
    if let Value::Array(items) = parse_list(&m.action_items_json) {
        if !items.is_empty() {
            out.push_str("\n## Action items\n\n");
            for item in items {
                // The app stores {owner, task, due, done}; accept "text" and plain strings too.
                let field = |k: &str| item.get(k).and_then(Value::as_str).filter(|s| !s.trim().is_empty());
                let mut text = match field("task").or_else(|| field("text")) {
                    Some(t) => t.to_string(),
                    None => item.as_str().map(str::to_string).unwrap_or_else(|| item.to_string()),
                };
                if let Some(owner) = field("owner") {
                    text = format!("{owner}: {text}");
                }
                if let Some(due) = field("due") {
                    text = format!("{text} ({due})");
                }
                let _ = writeln!(out, "- [{}] {text}", if is_done(&item) { "x" } else { " " });
            }
        }
    }
    if let Some(t) = m.raw_transcript_md.as_deref().filter(|t| !t.trim().is_empty()) {
        let _ = write!(out, "\n## Transcript\n\n{}\n", t.trim());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_since_formats() {
        assert_eq!(parse_since("1700000000000"), Some(1_700_000_000_000));
        assert_eq!(parse_since("1970-01-02"), Some(86_400_000));
        assert_eq!(parse_since("1970-01-01T00:00:01Z"), Some(1_000));
        assert_eq!(parse_since("last week"), None);
    }

    #[test]
    fn recognizes_done_items() {
        assert!(is_done(&json!({ "text": "a", "done": true })));
        assert!(is_done(&json!({ "text": "a", "status": "Completed" })));
        assert!(!is_done(&json!({ "text": "a", "done": false })));
        assert!(!is_done(&json!("plain string item")));
    }
}
