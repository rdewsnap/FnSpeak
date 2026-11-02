//! Shared team glossary: names and jargon every member's app should spell
//! the team's way. Any member can add terms; admins, or whoever added a
//! term, can remove it.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::args;
use crate::auth::AuthUser;
use crate::db::{new_id, now_ms, Row};
use crate::error::{ApiError, ApiResult};
use crate::teams::{role_in, Role};
use crate::AppState;

const MAX_TERM_CHARS: usize = 100;
const MAX_TERMS_PER_REQUEST: usize = 500;

fn term_json(r: &Row) -> Value {
    json!({ "id": r.text(0), "team_id": r.text(1), "term": r.text(2), "added_by": r.opt_text(3), "created_at": r.int(4) })
}

const TERM_COLS: &str = "g.id, g.team_id, g.term, u.email, g.created_at";

/// `GET /v1/teams/{id}/glossary`
pub async fn list(State(state): State<AppState>, user: AuthUser, Path(team_id): Path<String>) -> ApiResult<Json<Value>> {
    role_in(&state.db, &team_id, &user.user_id).await?;
    let rows = state
        .db
        .query(
            &format!(
                "SELECT {TERM_COLS} FROM glossary_terms g LEFT JOIN users u ON u.id = g.added_by
                 WHERE g.team_id = $1 ORDER BY g.term_key"
            ),
            args![&team_id],
        )
        .await?;
    Ok(Json(json!({ "terms": rows.iter().map(term_json).collect::<Vec<_>>() })))
}

/// `GET /v1/glossary`: terms from every team the caller is on, which is
/// what the app pulls into its vocabulary.
pub async fn mine(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let rows = state
        .db
        .query(
            &format!(
                "SELECT {TERM_COLS} FROM glossary_terms g LEFT JOIN users u ON u.id = g.added_by
                 WHERE g.team_id IN (SELECT team_id FROM memberships WHERE user_id = $1) ORDER BY g.term_key"
            ),
            args![&user.user_id],
        )
        .await?;
    Ok(Json(json!({ "terms": rows.iter().map(term_json).collect::<Vec<_>>() })))
}

#[derive(Deserialize)]
pub struct AddTerms {
    #[serde(default)]
    term: Option<String>,
    #[serde(default)]
    terms: Vec<String>,
}

/// `POST /v1/teams/{id}/glossary` with `{"term": ...}` or `{"terms": [...]}`.
/// Terms the team already has are skipped.
pub async fn add(
    State(state): State<AppState>,
    user: AuthUser,
    Path(team_id): Path<String>,
    Json(req): Json<AddTerms>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    role_in(&state.db, &team_id, &user.user_id).await?;
    let terms: Vec<String> = req.term.into_iter().chain(req.terms).collect();
    if terms.is_empty() || terms.len() > MAX_TERMS_PER_REQUEST {
        return Err(ApiError::bad(format!("send 1 to {MAX_TERMS_PER_REQUEST} terms")));
    }
    let mut added = Vec::new();
    for raw in terms {
        let term = raw.split_whitespace().collect::<Vec<_>>().join(" ");
        if term.is_empty() || term.chars().count() > MAX_TERM_CHARS {
            return Err(ApiError::bad(format!("terms must be 1 to {MAX_TERM_CHARS} characters")));
        }
        let id = new_id();
        let n = state
            .db
            .execute(
                "INSERT INTO glossary_terms (id, team_id, term, term_key, added_by, created_at)
                 VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (team_id, term_key) DO NOTHING",
                args![&id, &team_id, &term, term.to_lowercase(), &user.user_id, now_ms()],
            )
            .await?;
        if n == 1 {
            added.push(json!({ "id": id, "term": term }));
        }
    }
    Ok((StatusCode::CREATED, Json(json!({ "added": added }))))
}

/// `DELETE /v1/teams/{id}/glossary/{term_id}`
pub async fn remove(
    State(state): State<AppState>,
    user: AuthUser,
    Path((team_id, term_id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let role = role_in(&state.db, &team_id, &user.user_id).await?;
    let row = state
        .db
        .query_opt("SELECT added_by FROM glossary_terms WHERE id = $1 AND team_id = $2", args![&term_id, &team_id])
        .await?
        .ok_or(ApiError::NotFound)?;
    if role < Role::Admin && row.opt_text(0).as_deref() != Some(user.user_id.as_str()) {
        return Err(ApiError::forbidden("only admins or whoever added a term can remove it"));
    }
    state.db.execute("DELETE FROM glossary_terms WHERE id = $1", args![&term_id]).await?;
    Ok(StatusCode::NO_CONTENT)
}
