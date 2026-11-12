//! Teams, roles and email invites.
//!
//! Owners manage everything, admins invite and remove members, members
//! read what's shared with the team and add to its glossary.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::args;
use crate::auth::{hash_token, normalize_email, random_token, user_teams, AuthUser};
use crate::db::{new_id, now_ms, Batch, Db};
use crate::error::{ApiError, ApiResult};
use crate::mail::Mail;
use crate::AppState;

const INVITE_TTL_MS: i64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Role {
    Member,
    Admin,
    Owner,
}

impl Role {
    pub fn parse(s: &str) -> ApiResult<Role> {
        match s {
            "owner" => Ok(Role::Owner),
            "admin" => Ok(Role::Admin),
            "member" => Ok(Role::Member),
            _ => Err(ApiError::bad("role must be owner, admin or member")),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Role::Owner => "owner",
            Role::Admin => "admin",
            Role::Member => "member",
        }
    }
}

/// The caller's role in `team_id`. Non-members get 404 rather than 403 so
/// team ids can't be probed.
pub async fn role_in(db: &Db, team_id: &str, user_id: &str) -> ApiResult<Role> {
    let row = db
        .query_opt("SELECT role FROM memberships WHERE team_id = $1 AND user_id = $2", args![team_id, user_id])
        .await?
        .ok_or(ApiError::NotFound)?;
    Role::parse(&row.text(0))
}

async fn require(db: &Db, team_id: &str, user_id: &str, at_least: Role) -> ApiResult<Role> {
    let role = role_in(db, team_id, user_id).await?;
    if role < at_least {
        return Err(ApiError::forbidden(format!("needs the {} role on this team", at_least.as_str())));
    }
    Ok(role)
}

async fn is_personal(db: &Db, team_id: &str) -> ApiResult<bool> {
    let row = db.query_opt("SELECT personal FROM teams WHERE id = $1", args![team_id]).await?.ok_or(ApiError::NotFound)?;
    Ok(row.bool(0))
}

#[derive(Deserialize)]
pub struct NewTeam {
    name: String,
}

fn valid_name(name: &str) -> ApiResult<&str> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 100 {
        return Err(ApiError::bad("name must be 1 to 100 characters"));
    }
    Ok(name)
}

/// `POST /v1/teams`
pub async fn create(State(state): State<AppState>, user: AuthUser, Json(req): Json<NewTeam>) -> ApiResult<impl IntoResponse> {
    let name = valid_name(&req.name)?;
    let id = new_id();
    let now = now_ms();
    let mut batch = Batch::default();
    batch
        .push(
            "INSERT INTO teams (id, name, personal, created_by, created_at) VALUES ($1, $2, 0, $3, $4)",
            args![&id, name, &user.user_id, now],
        )
        .push(
            "INSERT INTO memberships (team_id, user_id, role, created_at) VALUES ($1, $2, 'owner', $3)",
            args![&id, &user.user_id, now],
        );
    state.db.transaction(batch.0).await?;
    Ok((StatusCode::CREATED, Json(json!({ "id": id, "name": name, "personal": false, "role": "owner" }))))
}

/// `GET /v1/teams`
pub async fn list(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    Ok(Json(json!({ "teams": user_teams(&state.db, &user.user_id).await? })))
}

/// `GET /v1/teams/{id}`: the team and its members.
pub async fn get(State(state): State<AppState>, user: AuthUser, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    let role = role_in(&state.db, &id, &user.user_id).await?;
    let team = state.db.query_one("SELECT id, name, personal, created_at FROM teams WHERE id = $1", args![&id]).await?;
    let members = state
        .db
        .query(
            "SELECT u.id, u.email, m.role, m.created_at FROM memberships m JOIN users u ON u.id = m.user_id
             WHERE m.team_id = $1 ORDER BY m.created_at",
            args![&id],
        )
        .await?;
    Ok(Json(json!({
        "id": team.text(0),
        "name": team.text(1),
        "personal": team.bool(2),
        "created_at": team.int(3),
        "role": role.as_str(),
        "members": members.iter().map(|m| json!({
            "user_id": m.text(0), "email": m.text(1), "role": m.text(2), "joined_at": m.int(3),
        })).collect::<Vec<_>>(),
    })))
}

/// `PATCH /v1/teams/{id}`: rename.
pub async fn update(
    State(state): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(req): Json<NewTeam>,
) -> ApiResult<StatusCode> {
    require(&state.db, &id, &user.user_id, Role::Admin).await?;
    let name = valid_name(&req.name)?;
    state.db.execute("UPDATE teams SET name = $1 WHERE id = $2", args![name, &id]).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct NewInvite {
    email: String,
    role: Option<String>,
}

/// `POST /v1/teams/{id}/invites`: email someone a link to join.
pub async fn invite(
    State(state): State<AppState>,
    user: AuthUser,
    Path(team_id): Path<String>,
    Json(req): Json<NewInvite>,
) -> ApiResult<impl IntoResponse> {
    let my_role = require(&state.db, &team_id, &user.user_id, Role::Admin).await?;
    if is_personal(&state.db, &team_id).await? {
        return Err(ApiError::bad("personal teams can't have other members; create a team first"));
    }
    let role = Role::parse(req.role.as_deref().unwrap_or("member"))?;
    if role > my_role {
        return Err(ApiError::forbidden("you can't invite someone with a higher role than yours"));
    }
    let email = normalize_email(&req.email)?;
    let already = state
        .db
        .query_opt(
            "SELECT 1 FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.team_id = $1 AND u.email = $2",
            args![&team_id, &email],
        )
        .await?;
    if already.is_some() {
        return Err(ApiError::Conflict(format!("{email} is already on this team")));
    }

    let id = new_id();
    let token = random_token("fsi_");
    let now = now_ms();
    let expires_at = now + INVITE_TTL_MS;
    state
        .db
        .execute(
            "INSERT INTO invites (id, team_id, email, role, token_hash, invited_by, created_at, expires_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
            args![&id, &team_id, &email, role.as_str(), hash_token(&state.config.secret, &token), &user.user_id, now, expires_at],
        )
        .await?;
    let team_name = state.db.query_one("SELECT name FROM teams WHERE id = $1", args![&team_id]).await?.text(0);
    let invite_link = format!("{}/v1/invites/{token}", state.config.base_url);
    state
        .mailer
        .send(Mail {
            to: email.clone(),
            subject: format!("{} invited you to {team_name} on FnSpeak", user.email),
            body: format!(
                "{} invited you to join {team_name} on FnSpeak as {}.\n\n\
                 Sign in to FnSpeak as {email}, then accept the invite with this link:\n\n{}/v1/invites/{token}\n\n\
                 The invite expires in 7 days.",
                user.email,
                role.as_str(),
                state.config.base_url,
            ),
            html: Some(crate::mail::html(&crate::mail::Layout {
                heading: &format!("Join {team_name} on FnSpeak"),
                intro: &format!(
                    "{} invited you to {team_name} as {} {}. You'll share the team's glossary and snippets, and anything teammates share with it.",
                    user.email,
                    if role == Role::Member { "a" } else { "an" },
                    role.as_str()
                ),
                button: None,
                copy: Some((
                    &format!("Sign in to FnSpeak as {email}, then paste this invite link in Settings, Account:"),
                    &invite_link,
                )),
                note: "The invite expires in 7 days. If you weren't expecting it, you can ignore this email.",
            })),
        })
        .await
        .map_err(crate::mail::send_failed)?;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "id": id, "team_id": team_id, "email": email, "role": role.as_str(), "expires_at": expires_at })),
    ))
}

/// `GET /v1/teams/{id}/invites`: pending invites.
pub async fn list_invites(State(state): State<AppState>, user: AuthUser, Path(team_id): Path<String>) -> ApiResult<Json<Value>> {
    require(&state.db, &team_id, &user.user_id, Role::Admin).await?;
    let rows = state
        .db
        .query(
            "SELECT id, email, role, created_at, expires_at FROM invites
             WHERE team_id = $1 AND accepted_at IS NULL AND expires_at > $2 ORDER BY created_at",
            args![&team_id, now_ms()],
        )
        .await?;
    let invites: Vec<Value> = rows
        .iter()
        .map(|r| json!({ "id": r.text(0), "email": r.text(1), "role": r.text(2), "created_at": r.int(3), "expires_at": r.int(4) }))
        .collect();
    Ok(Json(json!({ "invites": invites })))
}

/// `DELETE /v1/teams/{id}/invites/{invite_id}`
pub async fn revoke_invite(
    State(state): State<AppState>,
    user: AuthUser,
    Path((team_id, invite_id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    require(&state.db, &team_id, &user.user_id, Role::Admin).await?;
    let n = state
        .db
        .execute("DELETE FROM invites WHERE id = $1 AND team_id = $2 AND accepted_at IS NULL", args![invite_id, &team_id])
        .await?;
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn find_invite(state: &AppState, token: &str) -> ApiResult<crate::db::Row> {
    state
        .db
        .query_opt(
            "SELECT i.id, i.team_id, t.name, i.email, i.role, i.expires_at, i.accepted_at
             FROM invites i JOIN teams t ON t.id = i.team_id WHERE i.token_hash = $1",
            args![hash_token(&state.config.secret, token)],
        )
        .await?
        .ok_or(ApiError::NotFound)
}

/// `GET /v1/invites/{token}`: what the invite is for, without accepting it.
pub async fn show_invite(State(state): State<AppState>, Path(token): Path<String>) -> ApiResult<Json<Value>> {
    let r = find_invite(&state, &token).await?;
    let status = if r.opt_int(6).is_some() {
        "accepted"
    } else if r.int(5) <= now_ms() {
        "expired"
    } else {
        "pending"
    };
    Ok(Json(json!({
        "team": { "id": r.text(1), "name": r.text(2) },
        "email": r.text(3),
        "role": r.text(4),
        "expires_at": r.int(5),
        "status": status,
        "accept": format!("POST {}/v1/invites/{token}/accept", state.config.base_url),
    })))
}

/// `POST /v1/invites/{token}/accept`: join the team. The caller must be
/// signed in with the address the invite was sent to.
pub async fn accept_invite(
    State(state): State<AppState>,
    user: AuthUser,
    Path(token): Path<String>,
) -> ApiResult<Json<Value>> {
    let r = find_invite(&state, &token).await?;
    let (invite_id, team_id, team_name, email, role) = (r.text(0), r.text(1), r.text(2), r.text(3), r.text(4));
    if r.opt_int(6).is_some() || r.int(5) <= now_ms() {
        return Err(ApiError::bad("this invite has been used or has expired"));
    }
    if email != user.email {
        return Err(ApiError::forbidden(format!("this invite is for {email}; sign in with that address to accept it")));
    }
    let now = now_ms();
    let claimed = state
        .db
        .execute(
            "UPDATE invites SET accepted_at = $1, accepted_by = $2 WHERE id = $3 AND accepted_at IS NULL",
            args![now, &user.user_id, &invite_id],
        )
        .await?;
    if claimed != 1 {
        return Err(ApiError::bad("this invite has been used or has expired"));
    }
    let joined = state
        .db
        .execute(
            "INSERT INTO memberships (team_id, user_id, role, created_at) VALUES ($1, $2, $3, $4)
             ON CONFLICT (team_id, user_id) DO NOTHING",
            args![&team_id, &user.user_id, &role, now],
        )
        .await?;
    Ok(Json(json!({ "team": { "id": team_id, "name": team_name }, "role": role, "joined": joined == 1 })))
}

#[derive(Deserialize)]
pub struct RoleChange {
    role: String,
}

async fn owner_count(db: &Db, team_id: &str) -> ApiResult<i64> {
    Ok(db
        .query_one("SELECT COUNT(*) FROM memberships WHERE team_id = $1 AND role = 'owner'", args![team_id])
        .await?
        .int(0))
}

/// `PATCH /v1/teams/{id}/members/{user_id}`: change a member's role (owners only).
pub async fn set_role(
    State(state): State<AppState>,
    user: AuthUser,
    Path((team_id, member_id)): Path<(String, String)>,
    Json(req): Json<RoleChange>,
) -> ApiResult<StatusCode> {
    require(&state.db, &team_id, &user.user_id, Role::Owner).await?;
    let new_role = Role::parse(&req.role)?;
    let current = role_in(&state.db, &team_id, &member_id).await?;
    if current == Role::Owner && new_role != Role::Owner && owner_count(&state.db, &team_id).await? <= 1 {
        return Err(ApiError::bad("a team needs at least one owner"));
    }
    state
        .db
        .execute(
            "UPDATE memberships SET role = $1 WHERE team_id = $2 AND user_id = $3",
            args![new_role.as_str(), &team_id, &member_id],
        )
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

/// `DELETE /v1/teams/{id}/members/{user_id}`: remove a member, or leave.
pub async fn remove_member(
    State(state): State<AppState>,
    user: AuthUser,
    Path((team_id, member_id)): Path<(String, String)>,
) -> ApiResult<StatusCode> {
    let my_role = role_in(&state.db, &team_id, &user.user_id).await?;
    let their_role = role_in(&state.db, &team_id, &member_id).await?;
    let leaving = member_id == user.user_id;
    if !leaving && (my_role < Role::Admin || their_role > my_role || (their_role == Role::Admin && my_role == Role::Admin)) {
        return Err(ApiError::forbidden("you can't remove this member"));
    }
    if is_personal(&state.db, &team_id).await? {
        return Err(ApiError::bad("you can't leave your personal team"));
    }
    if their_role == Role::Owner && owner_count(&state.db, &team_id).await? <= 1 {
        return Err(ApiError::bad("a team needs at least one owner; make someone else owner first"));
    }
    state
        .db
        .execute("DELETE FROM memberships WHERE team_id = $1 AND user_id = $2", args![&team_id, &member_id])
        .await?;
    Ok(StatusCode::NO_CONTENT)
}
