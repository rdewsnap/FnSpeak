//! Sign-in by magic link, and the API tokens the app and MCP clients use.
//!
//! Signing in creates the account on first use, along with a personal team.
//! A verified magic link is exchanged for an API token; there are no cookie
//! sessions. Tokens are only ever stored hashed.

use axum::extract::{FromRequestParts, Path, State};
use axum::http::request::Parts;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::net::SocketAddr;
use std::time::Duration;

use crate::args;
use crate::db::{new_id, now_ms, Batch, Db};
use crate::error::{ApiError, ApiResult};
use crate::mail::Mail;
use crate::AppState;

const LINK_TTL_MS: i64 = 15 * 60 * 1000;
const RATE_WINDOW: Duration = Duration::from_secs(15 * 60);
const LINKS_PER_EMAIL: u32 = 5;
const AUTH_REQUESTS_PER_IP: u32 = 30;

/// 32 random bytes, hex-encoded, with a prefix that says what the token is
/// for (and makes leaked tokens easy to grep for).
pub fn random_token(prefix: &str) -> String {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("system random number generator unavailable");
    format!("{prefix}{}", hex::encode(bytes))
}

pub fn hash_token(secret: &str, token: &str) -> String {
    let mut h = Sha256::new();
    h.update(secret.as_bytes());
    h.update([0u8]);
    h.update(token.as_bytes());
    hex::encode(h.finalize())
}

pub fn normalize_email(email: &str) -> ApiResult<String> {
    let email = email.trim().to_lowercase();
    if email.len() > 254 || email.parse::<lettre::Address>().is_err() {
        return Err(ApiError::bad("not a valid email address"));
    }
    Ok(email)
}

/// The caller, resolved from `Authorization: Bearer <token>`.
#[derive(Clone, Debug)]
pub struct AuthUser {
    pub user_id: String,
    pub email: String,
    pub token_id: String,
}

impl AuthUser {
    pub async fn from_headers(state: &AppState, headers: &HeaderMap) -> ApiResult<AuthUser> {
        let token = headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer ").or_else(|| v.strip_prefix("bearer ")))
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .ok_or(ApiError::Unauthorized)?;
        let hash = hash_token(&state.config.secret, token);
        let row = state
            .db
            .query_opt(
                "SELECT t.id, u.id, u.email, t.last_used_at FROM api_tokens t JOIN users u ON u.id = t.user_id
                 WHERE t.token_hash = $1",
                args![hash],
            )
            .await?
            .ok_or(ApiError::Unauthorized)?;
        let now = now_ms();
        // Only touch last_used_at once a minute to keep reads from writing.
        if row.opt_int(3).is_none_or(|t| now - t > 60_000) {
            state.db.execute("UPDATE api_tokens SET last_used_at = $1 WHERE id = $2", args![now, row.text(0)]).await?;
        }
        Ok(AuthUser { token_id: row.text(0), user_id: row.text(1), email: row.text(2) })
    }
}

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        if let Some(user) = parts.extensions.get::<AuthUser>() {
            return Ok(user.clone());
        }
        let user = AuthUser::from_headers(state, &parts.headers).await?;
        parts.extensions.insert(user.clone());
        Ok(user)
    }
}

/// Best-effort client address for rate limiting.
pub struct ClientIp(pub String);

impl FromRequestParts<AppState> for ClientIp {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        if state.config.trust_proxy {
            if let Some(ip) = parts
                .headers
                .get("x-forwarded-for")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.split(',').next())
            {
                return Ok(ClientIp(ip.trim().to_string()));
            }
        }
        let ip = parts
            .extensions
            .get::<axum::extract::ConnectInfo<SocketAddr>>()
            .map(|c| c.0.ip().to_string())
            .unwrap_or_else(|| "unknown".into());
        Ok(ClientIp(ip))
    }
}

#[derive(Deserialize)]
pub struct LinkRequest {
    email: String,
    /// Page the link should open instead of this server's verify page, for a
    /// web front end that exchanges the token itself. Honoured only when its
    /// origin is one of `FNSPEAK_CORS_ORIGINS`; otherwise the server's own
    /// page is used so the link can never point somewhere unexpected.
    #[serde(default)]
    return_to: Option<String>,
}

/// Where the emailed link points, without the `?token=` part.
fn link_target(config: &crate::Config, return_to: Option<&str>) -> ApiResult<String> {
    let own = format!("{}/v1/auth/verify", config.base_url);
    let Some(raw) = return_to.map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(own);
    };
    let url = reqwest::Url::parse(raw).map_err(|_| ApiError::bad("return_to must be an absolute URL"))?;
    if url.query().is_some() || url.fragment().is_some() {
        return Err(ApiError::bad("return_to can't have a query string or fragment"));
    }
    let origin = url.origin().ascii_serialization();
    if config.cors_origins.iter().any(|o| o.trim_end_matches('/') == origin) {
        Ok(raw.to_string())
    } else {
        Ok(own)
    }
}

/// `POST /v1/auth/magic-link`. Always answers 202 so the endpoint can't be
/// used to find out which emails have accounts.
pub async fn request_link(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    Json(req): Json<LinkRequest>,
) -> ApiResult<impl IntoResponse> {
    let email = normalize_email(&req.email)?;
    if !state.limiter.allow(&format!("link-ip:{ip}"), AUTH_REQUESTS_PER_IP, RATE_WINDOW)
        || !state.limiter.allow(&format!("link-email:{email}"), LINKS_PER_EMAIL, RATE_WINDOW)
    {
        return Err(ApiError::TooManyRequests);
    }
    let token = random_token("fsl_");
    let now = now_ms();
    state
        .db
        .execute(
            "INSERT INTO login_tokens (token_hash, email, created_at, expires_at) VALUES ($1, $2, $3, $4)",
            args![hash_token(&state.config.secret, &token), &email, now, now + LINK_TTL_MS],
        )
        .await?;
    let link = format!("{}?token={token}", link_target(&state.config, req.return_to.as_deref())?);
    state
        .mailer
        .send(Mail {
            to: email,
            subject: "Your FnSpeak sign-in link".into(),
            body: format!(
                "Open this link to sign in to FnSpeak:\n\n{link}\n\nIt works once and expires in 15 minutes. \
                 If you didn't ask for it, ignore this email."
            ),
            html: Some(crate::mail::html(&crate::mail::Layout {
                heading: "Sign in to FnSpeak",
                intro: "Here's your sign-in link. Open it on the Mac where you use FnSpeak.",
                button: Some(("Sign in", &link)),
                copy: Some(("Or copy this link and paste it into FnSpeak:", &link)),
                note: "The link works once and expires in 15 minutes. If you didn't ask for it, you can ignore this email.",
            })),
        })
        .await
        .map_err(crate::mail::send_failed)?;
    Ok((StatusCode::ACCEPTED, Json(json!({ "status": "sent" }))))
}

/// `GET /v1/auth/verify`: the page the emailed link opens. It doesn't
/// consume the token itself, since mail scanners prefetch links; the button
/// does, with a POST.
pub async fn verify_page() -> Html<&'static str> {
    Html(include_str!("verify.html"))
}

#[derive(Deserialize)]
pub struct VerifyRequest {
    token: String,
    /// Label for the API token this creates, e.g. the device name.
    name: Option<String>,
}

#[derive(Serialize)]
pub struct VerifyResponse {
    token: String,
    token_id: String,
    user: Value,
}

/// `POST /v1/auth/verify`: exchange a magic-link token for an API token.
pub async fn verify(
    State(state): State<AppState>,
    ClientIp(ip): ClientIp,
    Json(req): Json<VerifyRequest>,
) -> ApiResult<Json<VerifyResponse>> {
    if !state.limiter.allow(&format!("verify-ip:{ip}"), AUTH_REQUESTS_PER_IP, RATE_WINDOW) {
        return Err(ApiError::TooManyRequests);
    }
    // An emailed link's token, or the app's half of a Google sign-in.
    let token = req.token.trim();
    let hash = if token.starts_with(crate::google::VERIFIER_PREFIX) {
        crate::google::claim_hash(&state.config.secret, token)
    } else {
        hash_token(&state.config.secret, token)
    };
    let now = now_ms();
    let row = state
        .db
        .query_opt(
            "SELECT email FROM login_tokens WHERE token_hash = $1 AND used_at IS NULL AND expires_at > $2",
            args![&hash, now],
        )
        .await?
        .ok_or_else(|| ApiError::bad("this sign-in link is invalid, used or expired"))?;
    // The conditional update makes the link single-use even under a race.
    let claimed = state
        .db
        .execute("UPDATE login_tokens SET used_at = $1 WHERE token_hash = $2 AND used_at IS NULL", args![now, &hash])
        .await?;
    if claimed != 1 {
        return Err(ApiError::bad("this sign-in link is invalid, used or expired"));
    }
    let email = row.text(0);
    let user_id = ensure_user(&state, &email).await?;
    let name = req.name.as_deref().map(str::trim).filter(|n| !n.is_empty()).unwrap_or("Sign-in");
    let (token_id, token) = create_api_token(&state, &user_id, name).await?;
    Ok(Json(VerifyResponse { token, token_id, user: json!({ "id": user_id, "email": email }) }))
}

/// Find the user for `email`, creating them and their personal team if new.
pub async fn ensure_user(state: &AppState, email: &str) -> ApiResult<String> {
    if let Some(row) = state.db.query_opt("SELECT id FROM users WHERE email = $1", args![email]).await? {
        return Ok(row.text(0));
    }
    let user_id = new_id();
    let team_id = new_id();
    let now = now_ms();
    let mut batch = Batch::default();
    batch
        .push("INSERT INTO users (id, email, created_at) VALUES ($1, $2, $3)", args![&user_id, email, now])
        .push(
            "INSERT INTO teams (id, name, personal, created_by, created_at) VALUES ($1, $2, 1, $3, $4)",
            args![&team_id, "Personal", &user_id, now],
        )
        .push(
            "INSERT INTO memberships (team_id, user_id, role, created_at) VALUES ($1, $2, 'owner', $3)",
            args![&team_id, &user_id, now],
        );
    match state.db.transaction(batch.0).await {
        Ok(_) => Ok(user_id),
        // Two first sign-ins racing: the other one created the user.
        Err(e) if e.is_unique_violation() => {
            Ok(state.db.query_one("SELECT id FROM users WHERE email = $1", args![email]).await?.text(0))
        }
        Err(e) => Err(e.into()),
    }
}

pub async fn create_api_token(state: &AppState, user_id: &str, name: &str) -> ApiResult<(String, String)> {
    let id = new_id();
    let token = random_token("fst_");
    state
        .db
        .execute(
            "INSERT INTO api_tokens (id, user_id, name, token_hash, created_at) VALUES ($1, $2, $3, $4, $5)",
            args![&id, user_id, name, hash_token(&state.config.secret, &token), now_ms()],
        )
        .await?;
    Ok((id, token))
}

/// `GET /v1/me`
pub async fn me(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let u = state.db.query_one("SELECT id, email, created_at FROM users WHERE id = $1", args![&user.user_id]).await?;
    let teams = user_teams(&state.db, &user.user_id).await?;
    Ok(Json(json!({
        "user": { "id": u.text(0), "email": u.text(1), "created_at": u.int(2) },
        "teams": teams,
    })))
}

pub async fn user_teams(db: &Db, user_id: &str) -> ApiResult<Vec<Value>> {
    let rows = db
        .query(
            "SELECT t.id, t.name, t.personal, m.role FROM memberships m JOIN teams t ON t.id = m.team_id
             WHERE m.user_id = $1 ORDER BY t.personal DESC, t.created_at",
            args![user_id],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| json!({ "id": r.text(0), "name": r.text(1), "personal": r.bool(2), "role": r.text(3) }))
        .collect())
}

#[derive(Deserialize)]
pub struct NewToken {
    name: String,
}

/// `POST /v1/tokens`: a new token for another device or an MCP client.
pub async fn create_token(
    State(state): State<AppState>,
    user: AuthUser,
    Json(req): Json<NewToken>,
) -> ApiResult<impl IntoResponse> {
    let name = req.name.trim();
    if name.is_empty() || name.len() > 100 {
        return Err(ApiError::bad("name must be 1 to 100 characters"));
    }
    let (id, token) = create_api_token(&state, &user.user_id, name).await?;
    Ok((StatusCode::CREATED, Json(json!({ "id": id, "name": name, "token": token }))))
}

/// `GET /v1/tokens`
pub async fn list_tokens(State(state): State<AppState>, user: AuthUser) -> ApiResult<Json<Value>> {
    let rows = state
        .db
        .query(
            "SELECT id, name, created_at, last_used_at FROM api_tokens WHERE user_id = $1 ORDER BY created_at",
            args![&user.user_id],
        )
        .await?;
    let tokens: Vec<Value> = rows
        .iter()
        .map(|r| {
            json!({
                "id": r.text(0),
                "name": r.text(1),
                "created_at": r.int(2),
                "last_used_at": r.opt_int(3),
                "current": r.text(0) == user.token_id,
            })
        })
        .collect();
    Ok(Json(json!({ "tokens": tokens })))
}

/// `DELETE /v1/tokens/{id}`
pub async fn delete_token(
    State(state): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> ApiResult<StatusCode> {
    let n = state.db.execute("DELETE FROM api_tokens WHERE id = $1 AND user_id = $2", args![id, &user.user_id]).await?;
    if n == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}
