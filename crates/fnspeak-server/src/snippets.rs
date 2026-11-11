//! Team snippets: trigger phrases that expand to saved text in every
//! member's dictations. Any member can add one; admins, or whoever added
//! it, can change or remove it. Snippet text is never logged.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::args;
use crate::auth::AuthUser;
use crate::db::{new_id, now_ms, Db, Row};
use crate::error::{ApiError, ApiResult};
use crate::teams::{role_in, Role};
use crate::AppState;

const MAX_TRIGGER_CHARS: usize = 60;
const MAX_TEXT_CHARS: usize = 4000;
/// The app's spoken commands. A trigger can't be one of them.
const COMMAND_PHRASES: &[&str] = &["scratch that", "new paragraph", "new line", "send it", "send that"];

const COLS: &str = "s.id, s.team_id, t.name, s.phrase, s.body, u.email, s.added_by, s.created_at, s.updated_at, m.role";
/// `$1` is the caller, whose membership both limits what they see and
/// gives their role for `can_edit`.
const FROM: &str = "FROM team_snippets s
     JOIN teams t ON t.id = s.team_id
     JOIN memberships m ON m.team_id = s.team_id AND m.user_id = $1
     LEFT JOIN users u ON u.id = s.added_by";

fn snippet_json(r: &Row, user_id: &str) -> ApiResult<Value> {
    let can_edit = Role::parse(&r.text(9))? >= Role::Admin || r.opt_text(6).as_deref() == Some(user_id);
    Ok(json!({
        "id": r.text(0),
        "team_id": r.text(1),
        "team_name": r.text(2),
        "trigger": r.text(3),
        "text": r.text(4),
        "added_by": r.opt_text(5),
        "can_edit": can_edit,
        "created_at": r.int(7),
        "updated_at": r.int(8),
    }))
}

/// Lowercase words joined by single spaces, where a word is a run of
/// letters, digits, apostrophes and hyphens. Must match the app's
/// `fnspeak_core::vocab::learn::heard_key`.
pub fn phrase_key(s: &str) -> String {
    s.split(|c: char| !(c.is_alphanumeric() || c == '\'' || c == '-'))
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
        .collect::<Vec<_>>()
        .join(" ")
}

/// The trigger with its whitespace collapsed, and its key.
fn clean_trigger(raw: &str) -> ApiResult<(String, String)> {
    let phrase = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if phrase.is_empty() || phrase.chars().count() > MAX_TRIGGER_CHARS {
        return Err(ApiError::bad(format!("triggers must be 1 to {MAX_TRIGGER_CHARS} characters")));
    }
    let key = phrase_key(&phrase);
    if key.split(' ').filter(|w| !w.is_empty()).count() < 2 {
        return Err(ApiError::bad("a trigger needs at least two words"));
    }
    if COMMAND_PHRASES.contains(&key.as_str()) {
        return Err(ApiError::bad(format!("\"{key}\" is a spoken command")));
    }
    Ok((phrase, key))
}

fn check_text(text: &str) -> ApiResult<()> {
    if text.trim().is_empty() || text.chars().count() > MAX_TEXT_CHARS {
        return Err(ApiError::bad(format!("snippet text must be 1 to {MAX_TEXT_CHARS} characters")));
    }
    Ok(())
}

fn taken() -> ApiError {
    ApiError::Conflict("this team already has a snippet with that trigger".into())
}

async fn fetch(db: &Db, user_id: &str, snippet_id: &str) -> ApiResult<Value> {
    let row = db
        .query_opt(&format!("SELECT {COLS} {FROM} WHERE s.id = $2"), args![user_id, snippet_id])
        .await?
        .ok_or(ApiError::NotFound)?;
    snippet_json(&row, user_id)
}

/// `GET /v1/teams/{id}/snippets`
pub async fn list(State(state): State<AppState>, user: AuthUser, Path(team_id): Path<String>) -> ApiResult<Json<Value>> {
    role_in(&state.db, &team_id, &user.user_id).await?;
    let rows = state
        .db
        .query(
            &format!("SELECT {COLS} {FROM} WHERE s.team_id = $2 ORDER BY s.phrase_key, s.id"),
            args![&user.user_id, &team_id],
        )
        .await?;
    let snippets = rows.iter().map(|r| snippet_json(r, &user.user_id)).collect::<ApiResult<Vec<_>>>()?;
    Ok(Json(json!({ "snippets": snippets })))
}

/// `GET /v1/snippets`: snippets from every team the caller is on, which is
/// what the app pulls.
pub async fn mine(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let rows = state
        .db
        .query(&format!("SELECT {COLS} {FROM} ORDER BY s.phrase_key, s.id"), args![&user.user_id])
        .await?;
    let snippets = rows.iter().map(|r| snippet_json(r, &user.user_id)).collect::<ApiResult<Vec<_>>>()?;
    Ok(Json(json!({ "snippets": snippets })))
}

#[derive(Deserialize)]
pub struct NewSnippet {
    trigger: String,
    text: String,
}

/// `POST /v1/teams/{id}/snippets` with `{"trigger": ..., "text": ...}`.
pub async fn add(
    State(state): State<AppState>,
    user: AuthUser,
    Path(team_id): Path<String>,
    Json(req): Json<NewSnippet>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    role_in(&state.db, &team_id, &user.user_id).await?;
    let (phrase, key) = clean_trigger(&req.trigger)?;
    check_text(&req.text)?;
    let id = new_id();
    let now = now_ms();
    let inserted = state
        .db
        .execute(
            "INSERT INTO team_snippets (id, team_id, phrase, phrase_key, body, added_by, created_at, updated_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
            args![&id, &team_id, &phrase, &key, &req.text, &user.user_id, now, now],
        )
        .await;
    match inserted {
        Ok(_) => {}
        Err(e) if e.is_unique_violation() => return Err(taken()),
        Err(e) => return Err(e.into()),
    }
    Ok((StatusCode::CREATED, Json(fetch(&state.db, &user.user_id, &id).await?)))
}

/// The row's `added_by`, phrase and body, if the caller may change it.
async fn editable(db: &Db, team_id: &str, snippet_id: &str, user_id: &str) -> ApiResult<Row> {
    let role = role_in(db, team_id, user_id).await?;
    let row = db
        .query_opt("SELECT added_by, phrase, body FROM team_snippets WHERE id = $1 AND team_id = $2", args![snippet_id, team_id])
        .await?
        .ok_or(ApiError::NotFound)?;
    if role < Role::Admin && row.opt_text(0).as_deref() != Some(user_id) {
        return Err(ApiError::forbidden("only admins or whoever added a snippet can change or remove it"));
    }
    Ok(row)
}

#[derive(Deserialize)]
pub struct EditSnippet {
    #[serde(default)]
    trigger: Option<String>,
    #[serde(default)]
    text: Option<String>,
}

/// `PATCH /v1/teams/{id}/snippets/{snippet_id}` with `trigger`, `text` or both.
pub async fn update(
    State(state): State<AppState>,
    user: AuthUser,
    Path((team_id, snippet_id)): Path<(String, String)>,
    Json(req): Json<EditSnippet>,
) -> ApiResult<Json<Value>> {
    let row = editable(&state.db, &team_id, &snippet_id, &user.user_id).await?;
    let (phrase, key) = clean_trigger(&req.trigger.unwrap_or_else(|| row.text(1)))?;
    let body = req.text.unwrap_or_else(|| row.text(2));
    check_text(&body)?;
    let updated = state
        .db
        .execute(
            "UPDATE team_snippets SET phrase = $2, phrase_key = $3, body = $4, updated_at = $5 WHERE id = $1",
            args![&snippet_id, &phrase, &key, &body, now_ms()],
        )
        .await;
    match updated {
        Ok(_) => {}
        Err(e) if e.is_unique_violation() => return Err(taken()),
        Err(e) => return Err(e.into()),
    }
    Ok(Json(fetch(&state.db, &user.user_id, &snippet_id).await?))
}

/// `DELETE /v1/teams/{id}/snippets/{snippet_id}`
pub async fn remove(
    State(state): State<AppState>,
    user: AuthUser,
    Path((team_id, snippet_id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    editable(&state.db, &team_id, &snippet_id, &user.user_id).await?;
    state.db.execute("DELETE FROM team_snippets WHERE id = $1", args![&snippet_id]).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_ignore_case_spacing_and_punctuation() {
        assert_eq!(phrase_key("  Support,  HOURS! "), "support hours");
        assert_eq!(phrase_key("Ryan's sign-off"), "ryan's sign-off");
        assert_eq!(phrase_key("..."), "");
    }
}
