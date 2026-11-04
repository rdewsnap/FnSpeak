mod common;

use axum::http::StatusCode;
use common::{team_with_member, TestApp};
use serde_json::json;

#[tokio::test]
async fn members_share_a_glossary() {
    let app = TestApp::new().await;
    let (owner, member, team_id) = team_with_member(&app, "gl-owner@example.com", "gl-member@example.com").await;
    let path = format!("/v1/teams/{team_id}/glossary");

    let (status, body) = app.post(&path, &owner, json!({ "terms": ["pgvector", "Kinju", "  Priya   Raman "] })).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["added"].as_array().unwrap().len(), 3);

    // Case-insensitive duplicates are skipped.
    let (_, body) = app.post(&path, &member, json!({ "terms": ["PGVector", "FnSpeak"] })).await;
    assert_eq!(body["added"].as_array().unwrap().len(), 1);

    let (_, mine) = app.get("/v1/glossary", &member).await;
    let terms: Vec<&str> = mine["terms"].as_array().unwrap().iter().map(|t| t["term"].as_str().unwrap()).collect();
    assert_eq!(terms, vec!["FnSpeak", "Kinju", "pgvector", "Priya Raman"]);

    // A member can't remove someone else's term, but the owner can.
    let kinju = mine["terms"].as_array().unwrap().iter().find(|t| t["term"] == "Kinju").unwrap();
    let del = format!("{path}/{}", kinju["id"].as_str().unwrap());
    assert_eq!(app.call("DELETE", &del, Some(&member), None).await.0, StatusCode::FORBIDDEN);
    assert_eq!(app.call("DELETE", &del, Some(&owner), None).await.0, StatusCode::NO_CONTENT);

    let outsider = app.sign_in("gl-outsider@example.com").await;
    assert_eq!(app.get(&path, &outsider).await.0, StatusCode::NOT_FOUND);
    let (_, theirs) = app.get("/v1/glossary", &outsider).await;
    assert!(theirs["terms"].as_array().unwrap().is_empty());
}
