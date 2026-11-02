//! REST endpoints for notes, meetings, sync and search.

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::auth::AuthUser;
use crate::db::now_ms;
use crate::error::{ApiError, ApiResult};
use crate::store::{self, MeetingIn, NoteIn, WriteOutcome};
use crate::AppState;

const MAX_BATCH: usize = 500;

#[derive(Deserialize)]
pub struct Page {
    limit: Option<i64>,
    offset: Option<i64>,
}

/// `GET /v1/notes`
pub async fn list_notes(State(state): State<AppState>, user: AuthUser, Query(p): Query<Page>) -> ApiResult<Json<Value>> {
    let notes = store::list_notes(&state.db, &user.user_id, p.limit.unwrap_or(100), p.offset.unwrap_or(0)).await?;
    Ok(Json(json!({ "notes": notes })))
}

/// `GET /v1/notes/{id}`
pub async fn get_note(State(state): State<AppState>, user: AuthUser, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    let note = store::get_note(&state.db, &user.user_id, &id).await?.ok_or(ApiError::NotFound)?;
    Ok(Json(json!(note)))
}

/// `PUT /v1/notes/{id}`: create or update. Older writes come back as
/// `"stale"` with the server's copy.
pub async fn put_note(
    State(state): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(mut note): Json<NoteIn>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    if note.id.is_empty() {
        note.id = id.clone();
    } else if note.id != id {
        return Err(ApiError::bad("id in the body doesn't match the URL"));
    }
    let outcome = store::upsert_note(&state.db, &user.user_id, note).await?;
    respond(outcome, store::get_note(&state.db, &user.user_id, &id).await?.map(|n| json!(n)))
}

/// `DELETE /v1/notes/{id}`: leaves a tombstone so other devices learn of it.
pub async fn delete_note(State(state): State<AppState>, user: AuthUser, Path(id): Path<String>) -> ApiResult<StatusCode> {
    let note = store::get_note(&state.db, &user.user_id, &id).await?.ok_or(ApiError::NotFound)?;
    if note.user_id != user.user_id {
        return Err(ApiError::forbidden("only the owner can delete this note"));
    }
    let tombstone = NoteIn {
        id,
        created_at: Some(note.created_at),
        updated_at: now_ms().max(note.updated_at + 1),
        source: note.source,
        deleted: true,
        ..Default::default()
    };
    store::upsert_note(&state.db, &user.user_id, tombstone).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct MeetingQuery {
    since: Option<i64>,
    limit: Option<i64>,
}

/// `GET /v1/meetings?since=<started_at ms>`
pub async fn list_meetings(
    State(state): State<AppState>,
    user: AuthUser,
    Query(q): Query<MeetingQuery>,
) -> ApiResult<Json<Value>> {
    let meetings = store::list_meetings(&state.db, &user.user_id, q.since, q.limit.unwrap_or(100)).await?;
    Ok(Json(json!({ "meetings": meetings })))
}

#[derive(Deserialize)]
pub struct MeetingDetail {
    #[serde(default)]
    include_transcript: bool,
}

/// `GET /v1/meetings/{id}?include_transcript=true`
pub async fn get_meeting(
    State(state): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Query(q): Query<MeetingDetail>,
) -> ApiResult<Json<Value>> {
    let meeting = store::get_meeting(&state.db, &user.user_id, &id, q.include_transcript, q.include_transcript)
        .await?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(json!(meeting)))
}

/// `PUT /v1/meetings/{id}`
pub async fn put_meeting(
    State(state): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(mut meeting): Json<MeetingIn>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    if meeting.id.is_empty() {
        meeting.id = id.clone();
    } else if meeting.id != id {
        return Err(ApiError::bad("id in the body doesn't match the URL"));
    }
    let outcome = store::upsert_meeting(&state.db, &user.user_id, meeting).await?;
    let current = store::get_meeting(&state.db, &user.user_id, &id, false, false).await?;
    respond(outcome, current.map(|m| json!(m)))
}

/// `DELETE /v1/meetings/{id}`
pub async fn delete_meeting(State(state): State<AppState>, user: AuthUser, Path(id): Path<String>) -> ApiResult<StatusCode> {
    let meeting = store::get_meeting(&state.db, &user.user_id, &id, false, false).await?.ok_or(ApiError::NotFound)?;
    if meeting.user_id != user.user_id {
        return Err(ApiError::forbidden("only the owner can delete this meeting"));
    }
    let tombstone = MeetingIn {
        id,
        started_at: meeting.started_at,
        ended_at: meeting.ended_at,
        updated_at: now_ms().max(meeting.updated_at + 1),
        status: meeting.status,
        deleted: true,
        ..Default::default()
    };
    store::upsert_meeting(&state.db, &user.user_id, tombstone).await?;
    Ok(StatusCode::NO_CONTENT)
}

fn respond(outcome: WriteOutcome, current: Option<Value>) -> ApiResult<(StatusCode, Json<Value>)> {
    match outcome {
        WriteOutcome::Forbidden => Err(ApiError::forbidden("this id belongs to another user's item")),
        _ => Ok((StatusCode::OK, Json(json!({ "status": outcome, "current": current })))),
    }
}

#[derive(Deserialize)]
pub struct SyncQuery {
    since: Option<i64>,
    limit: Option<i64>,
}

/// `GET /v1/sync?since=<cursor>`: changes visible to the caller.
pub async fn pull(State(state): State<AppState>, user: AuthUser, Query(q): Query<SyncQuery>) -> ApiResult<Json<Value>> {
    let changes = store::changes_since(&state.db, &user.user_id, q.since.unwrap_or(0), q.limit.unwrap_or(500)).await?;
    Ok(Json(json!({
        "notes": changes.notes,
        "meetings": changes.meetings,
        "cursor": changes.cursor,
        "more": changes.more,
    })))
}

#[derive(Deserialize, Default)]
#[serde(default)]
pub struct PushBatch {
    notes: Vec<NoteIn>,
    meetings: Vec<MeetingIn>,
}

/// `POST /v1/sync`: push a batch. Each item is applied on its own; the
/// response says what happened to each.
pub async fn push(State(state): State<AppState>, user: AuthUser, Json(batch): Json<PushBatch>) -> ApiResult<Json<Value>> {
    if batch.notes.len() + batch.meetings.len() > MAX_BATCH {
        return Err(ApiError::bad(format!("at most {MAX_BATCH} items per batch")));
    }
    let mut results = Vec::new();
    for note in batch.notes {
        let id = note.id.clone();
        let result = store::upsert_note(&state.db, &user.user_id, note).await;
        results.push(item_result("note", id, result)?);
    }
    for meeting in batch.meetings {
        let id = meeting.id.clone();
        let result = store::upsert_meeting(&state.db, &user.user_id, meeting).await;
        results.push(item_result("meeting", id, result)?);
    }
    Ok(Json(json!({ "results": results })))
}

/// Per-item validation problems go in the results; anything else fails the request.
fn item_result(kind: &str, id: String, result: ApiResult<WriteOutcome>) -> ApiResult<Value> {
    match result {
        Ok(outcome) => Ok(json!({ "kind": kind, "id": id, "status": outcome })),
        Err(e @ (ApiError::BadRequest(_) | ApiError::Forbidden(_))) => {
            Ok(json!({ "kind": kind, "id": id, "status": "rejected", "error": e.to_string() }))
        }
        Err(e) => Err(e),
    }
}

#[derive(Deserialize)]
pub struct SearchQuery {
    q: String,
    limit: Option<i64>,
}

/// `GET /v1/search?q=`
pub async fn search(State(state): State<AppState>, user: AuthUser, Query(q): Query<SearchQuery>) -> ApiResult<Json<Value>> {
    let hits = store::search(&state.db, &user.user_id, &q.q, q.limit.unwrap_or(20)).await?;
    Ok(Json(json!({ "results": hits })))
}
