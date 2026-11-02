mod common;

use axum::http::StatusCode;
use common::{team_with_member, TestApp};
use serde_json::{json, Value};

fn id() -> String {
    uuid::Uuid::now_v7().to_string()
}

fn note(id: &str, title: &str, body: &str, updated_at: i64) -> Value {
    json!({ "id": id, "created_at": 1_000, "updated_at": updated_at, "title": title, "body_md": body,
            "source": "dictation", "tags_json": "[\"eng\"]", "pinned": 0 })
}

fn ids(list: &Value) -> Vec<String> {
    list.as_array().unwrap().iter().map(|v| v["id"].as_str().unwrap().to_string()).collect()
}

#[tokio::test]
async fn team_member_sees_shared_note_but_not_private_one() {
    let app = TestApp::new().await;
    let (owner, member, team_id) = team_with_member(&app, "owner@example.com", "member@example.com").await;
    let outsider = app.sign_in("outsider@example.com").await;

    let (shared_id, private_id) = (id(), id());
    let mut shared = note(&shared_id, "Rollout plan", "Ship pgvector behind a flag", 2_000);
    shared["shared_with_team_id"] = json!(team_id);
    let (status, body) = app.put(&format!("/v1/notes/{shared_id}"), &owner, shared).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["status"], "applied");
    assert_eq!(body["current"]["visibility"], "team");
    let (status, _) =
        app.put(&format!("/v1/notes/{private_id}"), &owner, note(&private_id, "Diary", "pgvector is scary", 2_000)).await;
    assert_eq!(status, StatusCode::OK);

    let (_, list) = app.get("/v1/notes", &member).await;
    assert_eq!(ids(&list["notes"]), vec![shared_id.clone()]);
    assert_eq!(app.get(&format!("/v1/notes/{private_id}"), &member).await.0, StatusCode::NOT_FOUND);
    assert_eq!(app.get(&format!("/v1/notes/{shared_id}"), &outsider).await.0, StatusCode::NOT_FOUND);

    let (_, owner_list) = app.get("/v1/notes", &owner).await;
    assert_eq!(owner_list["notes"].as_array().unwrap().len(), 2);

    // Search respects the same visibility.
    let (_, hits) = app.get("/v1/search?q=pgvector", &member).await;
    assert_eq!(ids(&hits["results"]), vec![shared_id.clone()]);
    let (_, hits) = app.get("/v1/search?q=pgvector", &owner).await;
    assert_eq!(hits["results"].as_array().unwrap().len(), 2);

    // Members can read but not overwrite.
    let (status, _) =
        app.put(&format!("/v1/notes/{shared_id}"), &member, note(&shared_id, "Hijacked", "", 9_000)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Sharing with a team you're not on is refused.
    let mut sneaky = note(&id(), "x", "y", 1);
    sneaky["shared_with_team_id"] = json!(team_id);
    assert_eq!(app.put(&format!("/v1/notes/{}", sneaky["id"].as_str().unwrap()), &outsider, sneaky).await.0, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn last_writer_wins_by_updated_at() {
    let app = TestApp::new().await;
    let token = app.sign_in("lww@example.com").await;
    let note_id = id();
    let path = format!("/v1/notes/{note_id}");
    app.put(&path, &token, note(&note_id, "v2", "newer", 2_000)).await;

    let (status, body) = app.put(&path, &token, note(&note_id, "v1", "older", 1_500)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "stale");
    assert_eq!(body["current"]["title"], "v2");

    let (_, body) = app.put(&path, &token, note(&note_id, "v3", "newest", 3_000)).await;
    assert_eq!(body["status"], "applied");
    assert_eq!(body["current"]["title"], "v3");
    assert_eq!(body["current"]["tags_json"], "[\"eng\"]");
    assert_eq!(body["current"]["pinned"], false);
}

#[tokio::test]
async fn sync_since_returns_changes_and_tombstones() {
    let app = TestApp::new().await;
    let token = app.sign_in("sync@example.com").await;
    let (a, b, m) = (id(), id(), id());

    let (status, body) = app
        .post(
            "/v1/sync",
            &token,
            json!({
                "notes": [note(&a, "A", "first", 10), note(&b, "B", "second", 10), { "id": "not-a-uuid", "updated_at": 1 }],
                "meetings": [{
                    "id": m, "started_at": 5_000, "ended_at": 65_000, "updated_at": 70_000, "title": "Standup",
                    "participants_json": ["Ada", "Bo"], "status": "done", "summary_md": "Shipped the flag.",
                    "action_items_json": [{ "text": "Write the migration", "owner": "Bo", "done": false }],
                    "raw_transcript_md": "Ada: we shipped it",
                    "segments": [
                        { "started_ms": 0, "ended_ms": 1_500, "speaker": "Ada", "text": "we shipped it" },
                        { "started_ms": 1_500, "ended_ms": 2_000, "speaker": "Bo", "text": "nice" }
                    ]
                }],
            }),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let statuses: Vec<&str> = body["results"].as_array().unwrap().iter().map(|r| r["status"].as_str().unwrap()).collect();
    assert_eq!(statuses, vec!["applied", "applied", "rejected", "applied"]);

    let (_, first) = app.get("/v1/sync?since=0", &token).await;
    assert_eq!(first["notes"].as_array().unwrap().len(), 2);
    assert_eq!(first["meetings"][0]["segments"].as_array().unwrap().len(), 2);
    assert_eq!(first["meetings"][0]["participants_json"], "[\"Ada\",\"Bo\"]");
    assert_eq!(first["more"], false);
    let cursor = first["cursor"].as_i64().unwrap();

    // Nothing new since the cursor.
    let (_, empty) = app.get(&format!("/v1/sync?since={cursor}"), &token).await;
    assert!(empty["notes"].as_array().unwrap().is_empty() && empty["meetings"].as_array().unwrap().is_empty());
    assert_eq!(empty["cursor"], cursor);

    // A change and a deletion show up after it.
    app.put(&format!("/v1/notes/{a}"), &token, note(&a, "A2", "edited", 20)).await;
    assert_eq!(app.call("DELETE", &format!("/v1/notes/{b}"), Some(&token), None).await.0, StatusCode::NO_CONTENT);
    let (_, next) = app.get(&format!("/v1/sync?since={cursor}"), &token).await;
    let notes = next["notes"].as_array().unwrap();
    assert_eq!(notes.len(), 2);
    let deleted = notes.iter().find(|n| n["id"] == b.as_str()).unwrap();
    assert_eq!(deleted["deleted"], true);
    assert_eq!(deleted["body_md"], "");
    assert_eq!(notes.iter().find(|n| n["id"] == a.as_str()).unwrap()["title"], "A2");

    // Deleted notes drop out of lists and search.
    let (_, list) = app.get("/v1/notes", &token).await;
    assert_eq!(ids(&list["notes"]), vec![a.clone()]);
    let (_, hits) = app.get("/v1/search?q=second", &token).await;
    assert!(hits["results"].as_array().unwrap().is_empty());

    // Meetings are searchable by transcript.
    let (_, hits) = app.get("/v1/search?q=shipped", &token).await;
    assert_eq!(hits["results"][0]["kind"], "meeting");
}

#[tokio::test]
async fn sync_pages_with_a_cursor() {
    let app = TestApp::new().await;
    let token = app.sign_in("pages@example.com").await;
    let notes: Vec<Value> = (0..5).map(|i| note(&id(), &format!("n{i}"), "x", 10)).collect();
    app.post("/v1/sync", &token, json!({ "notes": notes })).await;

    let mut seen = Vec::new();
    let mut since = 0;
    loop {
        let (_, page) = app.get(&format!("/v1/sync?since={since}&limit=2"), &token).await;
        seen.extend(ids(&page["notes"]));
        since = page["cursor"].as_i64().unwrap();
        if page["more"] == false {
            break;
        }
    }
    assert_eq!(seen.len(), 5);
}

#[tokio::test]
async fn stale_meeting_push_keeps_existing_segments() {
    let app = TestApp::new().await;
    let token = app.sign_in("seg@example.com").await;
    let m = id();
    let path = format!("/v1/meetings/{m}");
    let meeting = |updated_at: i64, text: &str| {
        json!({ "started_at": 1, "updated_at": updated_at, "title": "1:1",
                "segments": [{ "started_ms": 0, "ended_ms": 10, "speaker": "A", "text": text }] })
    };
    app.put(&path, &token, meeting(200, "current")).await;
    let (_, body) = app.put(&path, &token, meeting(100, "outdated")).await;
    assert_eq!(body["status"], "stale");
    let (_, full) = app.get(&format!("{path}?include_transcript=true"), &token).await;
    assert_eq!(full["segments"][0]["text"], "current");
}
