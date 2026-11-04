#![allow(dead_code)]

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::Router;
use fnspeak_server::mail::{Mail, Mailer};
use fnspeak_server::{router, AppState, Config};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

pub struct TestApp {
    pub state: AppState,
    pub router: Router,
    pub outbox: Arc<Mutex<Vec<Mail>>>,
}

impl TestApp {
    pub async fn new() -> TestApp {
        Self::with_config(Config::for_tests()).await
    }

    /// Tests run on in-memory SQLite. Set FNSPEAK_TEST_POSTGRES_URL to a
    /// Postgres server (and build with `--features postgres`) to run them
    /// there instead, each test in a fresh database.
    pub async fn with_config(mut config: Config) -> TestApp {
        if let Ok(server) = std::env::var("FNSPEAK_TEST_POSTGRES_URL") {
            let admin = fnspeak_server::db::Db::connect(&server).await.expect("connect to test Postgres");
            let name = format!("fnspeak_test_{}", uuid::Uuid::now_v7().simple());
            admin.query(&format!("CREATE DATABASE {name}"), vec![]).await.expect("create test database");
            let base = server.rsplit_once('/').map(|(b, _)| b).unwrap_or(&server);
            config.database_url = format!("{base}/{name}");
        }
        let (mailer, outbox) = Mailer::memory();
        let state = AppState::new(config, mailer).await.expect("app state");
        TestApp { router: router(state.clone()), state, outbox }
    }

    pub async fn send(&self, req: Request<Body>) -> (StatusCode, Value) {
        let resp = self.router.clone().oneshot(req).await.expect("request");
        let status = resp.status();
        let bytes = resp.into_body().collect().await.expect("body").to_bytes();
        let body = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&bytes).into()))
        };
        (status, body)
    }

    pub async fn call(&self, method: &str, path: &str, token: Option<&str>, body: Option<Value>) -> (StatusCode, Value) {
        let mut req = Request::builder().method(method).uri(path).header("host", "localhost:8080");
        if let Some(t) = token {
            req = req.header("authorization", format!("Bearer {t}"));
        }
        let req = match body {
            Some(b) => req.header("content-type", "application/json").body(Body::from(b.to_string())),
            None => req.body(Body::empty()),
        };
        self.send(req.unwrap()).await
    }

    pub async fn get(&self, path: &str, token: &str) -> (StatusCode, Value) {
        self.call("GET", path, Some(token), None).await
    }

    pub async fn post(&self, path: &str, token: &str, body: Value) -> (StatusCode, Value) {
        self.call("POST", path, Some(token), Some(body)).await
    }

    pub async fn put(&self, path: &str, token: &str, body: Value) -> (StatusCode, Value) {
        self.call("PUT", path, Some(token), Some(body)).await
    }

    /// The token from the most recent email sent to `to`.
    pub fn last_token_for(&self, to: &str, param: &str) -> String {
        let outbox = self.outbox.lock().unwrap();
        let mail = outbox.iter().rev().find(|m| m.to == to).expect("no email sent");
        let start = mail.body.find(param).expect("no token in email") + param.len();
        mail.body[start..].chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect()
    }

    /// Sign in through the magic-link flow and return an API token.
    pub async fn sign_in(&self, email: &str) -> String {
        let (status, _) =
            self.call("POST", "/v1/auth/magic-link", None, Some(serde_json::json!({ "email": email }))).await;
        assert_eq!(status, StatusCode::ACCEPTED);
        let link_token = self.last_token_for(&email.to_lowercase(), "token=");
        let (status, body) =
            self.call("POST", "/v1/auth/verify", None, Some(serde_json::json!({ "token": link_token }))).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body["token"].as_str().unwrap().to_string()
    }
}

/// Owner creates a team and invites `member`, who accepts. Returns
/// (owner token, member token, team id).
pub async fn team_with_member(app: &TestApp, owner: &str, member: &str) -> (String, String, String) {
    let owner_token = app.sign_in(owner).await;
    let member_token = app.sign_in(member).await;
    let (status, team) = app.post("/v1/teams", &owner_token, json!({ "name": "Platform" })).await;
    assert_eq!(status, StatusCode::CREATED);
    let team_id = team["id"].as_str().unwrap().to_string();

    let (status, _) = app.post(&format!("/v1/teams/{team_id}/invites"), &owner_token, json!({ "email": member })).await;
    assert_eq!(status, StatusCode::CREATED);
    let invite = app.last_token_for(member, "/v1/invites/");
    let (status, body) = app.post(&format!("/v1/invites/{invite}/accept"), &member_token, json!({})).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    (owner_token, member_token, team_id)
}
