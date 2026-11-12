//! Sign in with Google, for servers that have a Google OAuth client.
//!
//! The app never sees a Google credential and the browser never sees an
//! FnSpeak one. The app makes up a secret (the verifier), and opens the
//! browser here with only its SHA-256 (the challenge). After Google vouches
//! for an email address, the server files a one-time sign-in under that
//! challenge. The app then trades the verifier for an API token through the
//! same `/v1/auth/verify` the emailed links use. Nothing that passes through
//! the browser, or the `fnspeak://signin` nudge back to the app, is enough
//! to sign in.

use axum::extract::{Query, State};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::args;
use crate::auth::{hash_token, normalize_email};
use crate::config::GoogleConfig;
use crate::db::now_ms;
use crate::error::{ApiError, ApiResult};
use crate::AppState;

/// How long the app has to collect a finished Google sign-in.
const CLAIM_TTL_MS: i64 = 5 * 60 * 1000;
/// Verifiers start with this, so `/v1/auth/verify` can tell them from emailed links.
pub const VERIFIER_PREFIX: &str = "fsg_";

/// The key a pending Google sign-in is filed under, from the app's verifier.
pub fn claim_hash(secret: &str, verifier: &str) -> String {
    challenge_hash(secret, &hex::encode(Sha256::digest(verifier.as_bytes())))
}

fn challenge_hash(secret: &str, challenge: &str) -> String {
    hash_token(secret, &format!("google:{challenge}"))
}

fn is_challenge(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn google(state: &AppState) -> ApiResult<&GoogleConfig> {
    state.config.google.as_ref().ok_or(ApiError::NotFound)
}

fn redirect_uri(state: &AppState) -> String {
    format!("{}/v1/auth/google/callback", state.config.base_url)
}

fn encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// `GET /v1/auth/providers`: the ways to sign in besides an emailed link.
pub async fn providers(State(state): State<AppState>) -> Json<Value> {
    Json(json!({ "google": state.config.google.is_some() }))
}

#[derive(Deserialize)]
pub struct StartQuery {
    challenge: String,
}

/// `GET /v1/auth/google?challenge=…`: send the browser to Google.
pub async fn start(State(state): State<AppState>, Query(q): Query<StartQuery>) -> ApiResult<Redirect> {
    let cfg = google(&state)?;
    if !is_challenge(&q.challenge) {
        return Err(ApiError::bad("challenge must be a SHA-256 in lowercase hex"));
    }
    Ok(Redirect::to(&format!(
        "{}?response_type=code&client_id={}&redirect_uri={}&scope={}&state={}&prompt=select_account",
        cfg.auth_url,
        encode(&cfg.client_id),
        encode(&redirect_uri(&state)),
        encode("openid email"),
        q.challenge,
    )))
}

#[derive(Deserialize)]
pub struct CallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

/// `GET /v1/auth/google/callback`: where Google sends the browser back.
pub async fn callback(State(state): State<AppState>, Query(q): Query<CallbackQuery>) -> Response {
    match finish(&state, q).await {
        Ok(email) => page("You're signed in", &format!("Signed in as {email}. Go back to FnSpeak to finish."), true),
        Err(message) => page("That didn't work", &message, false),
    }
}

async fn finish(state: &AppState, q: CallbackQuery) -> Result<String, String> {
    let again = "Go back to FnSpeak and try again.";
    let cfg = state.config.google.as_ref().ok_or("This server doesn't offer Google sign-in.")?;
    if q.error.is_some() {
        return Err(format!("Google sign-in was cancelled. {again}"));
    }
    let (Some(code), Some(challenge)) = (q.code, q.state.filter(|s| is_challenge(s))) else {
        return Err(format!("This sign-in link is incomplete. {again}"));
    };

    let form = [
        ("grant_type", "authorization_code"),
        ("code", code.as_str()),
        ("client_id", cfg.client_id.as_str()),
        ("client_secret", cfg.client_secret.as_str()),
        ("redirect_uri", &redirect_uri(state)),
    ];
    let body: String = form.iter().map(|(k, v)| format!("{k}={}", encode(v))).collect::<Vec<_>>().join("&");
    let failed = |what: &str| {
        tracing::warn!(what, "Google sign-in failed");
        format!("Google couldn't confirm your account. {again}")
    };
    let resp = state
        .http
        .post(&cfg.token_url)
        .header("content-type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .map_err(|_| failed("token request"))?;
    if !resp.status().is_success() {
        return Err(failed("token response"));
    }
    let tokens: Value = resp.json().await.map_err(|_| failed("token body"))?;
    // The ID token came straight from Google over TLS, so its signature
    // doesn't need checking; who it is for and when it expires still do.
    let claims = tokens["id_token"].as_str().and_then(jwt_claims).ok_or_else(|| failed("id token"))?;
    let issuer_ok = matches!(claims["iss"].as_str(), Some("https://accounts.google.com" | "accounts.google.com"));
    let current = claims["exp"].as_i64().is_some_and(|exp| exp * 1000 > now_ms());
    if claims["aud"].as_str() != Some(cfg.client_id.as_str()) || !issuer_ok || !current {
        return Err(failed("id token claims"));
    }
    let verified = claims["email_verified"].as_bool().unwrap_or(false) || claims["email_verified"].as_str() == Some("true");
    if !verified {
        return Err("Google hasn't verified that email address, so it can't be used to sign in.".into());
    }
    let email = claims["email"].as_str().and_then(|e| normalize_email(e).ok()).ok_or_else(|| failed("email"))?;

    let now = now_ms();
    state
        .db
        .execute(
            "INSERT INTO login_tokens (token_hash, email, created_at, expires_at) VALUES ($1, $2, $3, $4)",
            args![challenge_hash(&state.config.secret, &challenge), &email, now, now + CLAIM_TTL_MS],
        )
        .await
        // The same challenge twice: a reloaded page. The first one stands.
        .map_err(|_| format!("This sign-in was already used. {again}"))?;
    Ok(email)
}

/// The claims of a JWT, without checking its signature.
fn jwt_claims(token: &str) -> Option<Value> {
    let payload = token.split('.').nth(1)?;
    let mut bits = 0u32;
    let mut count = 0;
    let mut bytes = Vec::with_capacity(payload.len() * 3 / 4);
    for c in payload.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            b'=' => continue,
            _ => return None,
        };
        bits = (bits << 6) | u32::from(v);
        count += 6;
        if count >= 8 {
            count -= 8;
            bytes.push((bits >> count) as u8);
            bits &= (1 << count) - 1;
        }
    }
    serde_json::from_slice(&bytes).ok()
}

fn page(heading: &str, message: &str, nudge: bool) -> Response {
    let esc = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    // The link back carries nothing: it only tells the app to collect the sign-in.
    let script = if nudge { r#"<script>location.href = "fnspeak://signin";</script>"# } else { "" };
    Html(format!(
        r##"<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>FnSpeak</title>
<style>
  body {{ font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 32rem; margin: 4rem auto; padding: 0 1rem; color: #141311; background: #fcfcfb; }}
  @media (prefers-color-scheme: dark) {{ body {{ color: #ecebe6; background: #15161a; }} }}
  h1 {{ font: 500 1.6rem/1.2 Georgia, serif; }}
</style></head>
<body><h1>{}</h1><p>{}</p>{script}</body></html>
"##,
        esc(heading),
        esc(message),
    ))
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_claims_from_an_unpadded_base64url_payload() {
        // {"email":"a@example.com","n":"??>"} - the "??>" forces - and _ in the encoding.
        let claims = jwt_claims("x.eyJlbWFpbCI6ImFAZXhhbXBsZS5jb20iLCJuIjoiPz8-In0.y").unwrap();
        assert_eq!(claims["email"], "a@example.com");
        assert_eq!(claims["n"], "??>");
        assert!(jwt_claims("not-a-jwt").is_none());
        assert!(jwt_claims("a.!!!.c").is_none());
    }

    #[test]
    fn a_challenge_is_64_lowercase_hex() {
        assert!(is_challenge(&"ab12".repeat(16)));
        assert!(!is_challenge(&"AB12".repeat(16)));
        assert!(!is_challenge("abc"));
        assert!(!is_challenge(&format!("{}&x=1", "a".repeat(60))));
    }
}
