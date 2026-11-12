mod common;

use axum::http::StatusCode;
use common::TestApp;
use serde_json::json;

#[tokio::test]
async fn health_check() {
    let app = TestApp::new().await;
    let (status, body) = app.call("GET", "/healthz", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "ok");
}

#[tokio::test]
async fn magic_link_signs_up_and_creates_personal_team() {
    let app = TestApp::new().await;
    let token = app.sign_in("Ada@Example.com").await;
    assert!(token.starts_with("fst_"));

    let (status, me) = app.get("/v1/me", &token).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(me["user"]["email"], "ada@example.com");
    assert_eq!(me["teams"].as_array().unwrap().len(), 1);
    assert_eq!(me["teams"][0]["personal"], true);
    assert_eq!(me["teams"][0]["role"], "owner");

    // Signing in again finds the same account.
    let again = app.sign_in("ada@example.com").await;
    let (_, me2) = app.get("/v1/me", &again).await;
    assert_eq!(me2["user"]["id"], me["user"]["id"]);
}

#[tokio::test]
async fn magic_link_is_single_use() {
    let app = TestApp::new().await;
    app.call("POST", "/v1/auth/magic-link", None, Some(json!({ "email": "bo@example.com" }))).await;
    let link = app.last_token_for("bo@example.com", "token=");
    let (first, _) = app.call("POST", "/v1/auth/verify", None, Some(json!({ "token": link }))).await;
    let (second, body) = app.call("POST", "/v1/auth/verify", None, Some(json!({ "token": link }))).await;
    assert_eq!(first, StatusCode::OK);
    assert_eq!(second, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"]["code"], "bad_request");
}

#[tokio::test]
async fn rejects_missing_and_bad_tokens() {
    let app = TestApp::new().await;
    let (status, _) = app.call("GET", "/v1/me", None, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = app.get("/v1/me", "fst_nope").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn rate_limits_magic_links_per_email() {
    let app = TestApp::new().await;
    let mut statuses = Vec::new();
    for _ in 0..7 {
        let (s, _) = app.call("POST", "/v1/auth/magic-link", None, Some(json!({ "email": "cy@example.com" }))).await;
        statuses.push(s);
    }
    assert_eq!(statuses.iter().filter(|s| **s == StatusCode::ACCEPTED).count(), 5);
    assert_eq!(statuses.last(), Some(&StatusCode::TOO_MANY_REQUESTS));
}

#[tokio::test]
async fn api_tokens_can_be_created_listed_and_revoked() {
    let app = TestApp::new().await;
    let token = app.sign_in("di@example.com").await;
    let (status, created) = app.post("/v1/tokens", &token, json!({ "name": "Claude Desktop" })).await;
    assert_eq!(status, StatusCode::CREATED);
    let mcp_token = created["token"].as_str().unwrap();
    assert_eq!(app.get("/v1/me", mcp_token).await.0, StatusCode::OK);

    let (_, list) = app.get("/v1/tokens", &token).await;
    assert_eq!(list["tokens"].as_array().unwrap().len(), 2);
    assert!(list.to_string().find("fst_").is_none(), "token list must not leak secrets");

    let id = created["id"].as_str().unwrap();
    let (status, _) = app.call("DELETE", &format!("/v1/tokens/{id}"), Some(&token), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(app.get("/v1/me", mcp_token).await.0, StatusCode::UNAUTHORIZED);
}

fn last_link_for(app: &TestApp, to: &str) -> String {
    let outbox = app.outbox.lock().unwrap();
    let mail = outbox.iter().rev().find(|m| m.to == to).expect("no email sent");
    let start = mail.body.find("http").expect("no link in email");
    mail.body[start..].split_whitespace().next().unwrap().to_string()
}

#[tokio::test]
async fn magic_link_can_return_to_an_allowed_origin() {
    let app = TestApp::new().await;
    let body = json!({ "email": "a@example.com", "return_to": "http://localhost:8080/account/verify" });
    let (status, _) = app.call("POST", "/v1/auth/magic-link", None, Some(body)).await;
    assert_eq!(status, StatusCode::ACCEPTED);
    let link = last_link_for(&app, "a@example.com");
    assert!(link.starts_with("http://localhost:8080/account/verify?token=fsl_"), "{link}");
}

#[tokio::test]
async fn magic_link_ignores_an_unknown_return_origin() {
    let app = TestApp::new().await;
    let body = json!({ "email": "a@example.com", "return_to": "https://evil.example/verify" });
    app.call("POST", "/v1/auth/magic-link", None, Some(body)).await;
    let link = last_link_for(&app, "a@example.com");
    assert!(link.starts_with("http://localhost:8080/v1/auth/verify?token=fsl_"), "{link}");
}

#[tokio::test]
async fn magic_link_rejects_a_return_url_with_a_query() {
    let app = TestApp::new().await;
    let body = json!({ "email": "a@example.com", "return_to": "http://localhost:8080/account/verify?x=1" });
    let (status, _) = app.call("POST", "/v1/auth/magic-link", None, Some(body)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}
