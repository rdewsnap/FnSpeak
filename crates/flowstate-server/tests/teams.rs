mod common;

use axum::http::StatusCode;
use common::TestApp;
use serde_json::{json, Value};

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

#[tokio::test]
async fn create_team_invite_and_accept() {
    let app = TestApp::new().await;
    let (owner, member, team_id) = team_with_member(&app, "owner@example.com", "member@example.com").await;

    let (status, team) = app.get(&format!("/v1/teams/{team_id}"), &member).await;
    assert_eq!(status, StatusCode::OK);
    let members = team["members"].as_array().unwrap();
    assert_eq!(members.len(), 2);
    let roles: Vec<(&str, &str)> =
        members.iter().map(|m| (m["email"].as_str().unwrap(), m["role"].as_str().unwrap())).collect();
    assert!(roles.contains(&("owner@example.com", "owner")));
    assert!(roles.contains(&("member@example.com", "member")));

    let (_, teams) = app.get("/v1/teams", &member).await;
    assert_eq!(teams["teams"].as_array().unwrap().len(), 2, "personal team plus the new one");

    // Members can't invite.
    let (status, _) =
        app.post(&format!("/v1/teams/{team_id}/invites"), &member, json!({ "email": "x@example.com" })).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // The owner can promote them, after which they can.
    let member_id = members.iter().find(|m| m["role"] == "member").unwrap()["user_id"].as_str().unwrap();
    let (status, _) = app
        .call("PATCH", &format!("/v1/teams/{team_id}/members/{member_id}"), Some(&owner), Some(json!({ "role": "admin" })))
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) =
        app.post(&format!("/v1/teams/{team_id}/invites"), &member, json!({ "email": "x@example.com" })).await;
    assert_eq!(status, StatusCode::CREATED);
}

#[tokio::test]
async fn invite_is_bound_to_its_email_and_single_use() {
    let app = TestApp::new().await;
    let owner = app.sign_in("o@example.com").await;
    let stranger = app.sign_in("stranger@example.com").await;
    let (_, team) = app.post("/v1/teams", &owner, json!({ "name": "Design" })).await;
    let team_id = team["id"].as_str().unwrap();
    app.post(&format!("/v1/teams/{team_id}/invites"), &owner, json!({ "email": "Invitee@Example.com" })).await;
    let invite = app.last_token_for("invitee@example.com", "/v1/invites/");

    let (status, info) = app.call("GET", &format!("/v1/invites/{invite}"), None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(info["team"]["name"], "Design");
    assert_eq!(info["status"], "pending");

    let (status, _) = app.post(&format!("/v1/invites/{invite}/accept"), &stranger, json!({})).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let invitee = app.sign_in("invitee@example.com").await;
    let (status, _) = app.post(&format!("/v1/invites/{invite}/accept"), &invitee, json!({})).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = app.post(&format!("/v1/invites/{invite}/accept"), &invitee, json!({})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn outsiders_cant_see_a_team_and_personal_teams_cant_invite() {
    let app = TestApp::new().await;
    let a = app.sign_in("a@example.com").await;
    let b = app.sign_in("b@example.com").await;
    let (_, team) = app.post("/v1/teams", &a, json!({ "name": "Secret" })).await;
    let (status, _) = app.get(&format!("/v1/teams/{}", team["id"].as_str().unwrap()), &b).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (_, me) = app.get("/v1/me", &a).await;
    let personal = me["teams"].as_array().unwrap().iter().find(|t| t["personal"] == Value::Bool(true)).unwrap();
    let (status, _) = app
        .post(&format!("/v1/teams/{}/invites", personal["id"].as_str().unwrap()), &a, json!({ "email": "b@example.com" }))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn last_owner_cant_leave() {
    let app = TestApp::new().await;
    let (owner, member, team_id) = team_with_member(&app, "solo@example.com", "m@example.com").await;
    let (_, me) = app.get("/v1/me", &owner).await;
    let owner_id = me["user"]["id"].as_str().unwrap();
    let (status, _) = app.call("DELETE", &format!("/v1/teams/{team_id}/members/{owner_id}"), Some(&owner), None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (_, me) = app.get("/v1/me", &member).await;
    let member_id = me["user"]["id"].as_str().unwrap();
    let (status, _) = app.call("DELETE", &format!("/v1/teams/{team_id}/members/{member_id}"), Some(&member), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}
