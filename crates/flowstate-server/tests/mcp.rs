mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use common::{team_with_member, TestApp};
use serde_json::{json, Value};

async fn rpc(app: &TestApp, token: Option<&str>, method: &str, params: Value) -> (StatusCode, Value) {
    let mut req = Request::builder()
        .method("POST")
        .uri("/mcp")
        .header("host", "localhost:8080")
        .header("content-type", "application/json")
        .header("accept", "application/json, text/event-stream");
    if let Some(t) = token {
        req = req.header("authorization", format!("Bearer {t}"));
    }
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
    app.send(req.body(Body::from(body.to_string())).unwrap()).await
}

/// The JSON a tool returned in its first text block.
fn tool_json(resp: &Value) -> Value {
    let text = resp["result"]["content"][0]["text"].as_str().unwrap_or_else(|| panic!("no tool output: {resp}"));
    serde_json::from_str(text).unwrap()
}

async fn put_note(app: &TestApp, token: &str, title: &str, body: &str, team: Option<&str>) -> String {
    let id = uuid::Uuid::now_v7().to_string();
    let mut note = json!({ "updated_at": 1_000, "title": title, "body_md": body });
    if let Some(team) = team {
        note["shared_with_team_id"] = json!(team);
    }
    let (status, _) = app.put(&format!("/v1/notes/{id}"), token, note).await;
    assert_eq!(status, StatusCode::OK);
    id
}

#[tokio::test]
async fn requires_a_token() {
    let app = TestApp::new().await;
    let (status, _) = rpc(&app, None, "tools/list", json!({})).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = rpc(&app, Some("fst_wrong"), "tools/list", json!({})).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn initialize_and_list_tools() {
    let app = TestApp::new().await;
    let token = app.sign_in("mcp@example.com").await;

    let (status, init) = rpc(
        &app,
        Some(&token),
        "initialize",
        json!({ "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": { "name": "test", "version": "1" } }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{init}");
    assert_eq!(init["result"]["serverInfo"]["name"], "flowstate");

    let (status, list) = rpc(&app, Some(&token), "tools/list", json!({})).await;
    assert_eq!(status, StatusCode::OK, "{list}");
    let mut names: Vec<&str> =
        list["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
    names.sort();
    assert_eq!(
        names,
        vec![
            "create_note",
            "get_meeting",
            "get_meeting_summary",
            "get_note",
            "list_action_items",
            "list_meetings",
            "search_notes"
        ]
    );
}

#[tokio::test]
async fn search_notes_is_scoped_to_the_token_user() {
    let app = TestApp::new().await;
    let (owner, member, team_id) = team_with_member(&app, "mcp-owner@example.com", "mcp-member@example.com").await;
    let shared = put_note(&app, &owner, "Launch checklist", "Rotate the billing webhook secret", Some(&team_id)).await;
    put_note(&app, &owner, "Private", "billing dispute with landlord", None).await;

    let (_, resp) =
        rpc(&app, Some(&member), "tools/call", json!({ "name": "search_notes", "arguments": { "query": "billing" } })).await;
    let results = tool_json(&resp)["results"].as_array().unwrap().clone();
    assert_eq!(results.len(), 1, "{results:?}");
    assert_eq!(results[0]["id"], shared.as_str());
    assert_eq!(results[0]["uri"], format!("flowstate://notes/{shared}"));

    let (_, resp) =
        rpc(&app, Some(&owner), "tools/call", json!({ "name": "search_notes", "arguments": { "query": "billing" } })).await;
    assert_eq!(tool_json(&resp)["results"].as_array().unwrap().len(), 2);

    let (_, resp) = rpc(&app, Some(&member), "tools/call", json!({ "name": "get_note", "arguments": { "id": shared } })).await;
    assert_eq!(tool_json(&resp)["body_md"], "Rotate the billing webhook secret");

    let (_, resp) = rpc(
        &app,
        Some(&member),
        "resources/read",
        json!({ "uri": format!("flowstate://notes/{shared}") }),
    )
    .await;
    assert!(resp["result"]["contents"][0]["text"].as_str().unwrap().starts_with("# Launch checklist"));

    let (_, resp) = rpc(&app, Some(&member), "resources/list", json!({})).await;
    assert_eq!(resp["result"]["resources"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn meetings_action_items_and_create_note() {
    let app = TestApp::new().await;
    let token = app.sign_in("mcp-meet@example.com").await;
    let id = uuid::Uuid::now_v7().to_string();
    let meeting = json!({
        "started_at": 1_790_000_000_000_i64, "updated_at": 1, "title": "Planning",
        "summary_md": "Agreed to ship Friday.", "raw_transcript_md": "Ada: let's ship Friday",
        "action_items_json": [{ "owner": "Me", "task": "Write release notes", "due": "Thursday", "done": false },
                              { "owner": null, "task": "Book room", "due": null, "done": true }],
    });
    app.put(&format!("/v1/meetings/{id}"), &token, meeting).await;

    let call = |name: &'static str, args: Value| {
        let app = &app;
        let token = token.clone();
        async move { rpc(app, Some(&token), "tools/call", json!({ "name": name, "arguments": args })).await.1 }
    };

    let listed = tool_json(&call("list_meetings", json!({ "since": "2026-01-01" })).await);
    assert_eq!(listed["meetings"][0]["title"], "Planning");
    assert!(listed["meetings"][0].get("transcript_md").is_none());

    let summary = tool_json(&call("get_meeting_summary", json!({ "id": id })).await);
    assert_eq!(summary["summary_md"], "Agreed to ship Friday.");

    let full = tool_json(&call("get_meeting", json!({ "id": id, "include_transcript": true })).await);
    assert_eq!(full["transcript_md"], "Ada: let's ship Friday");

    let open = tool_json(&call("list_action_items", json!({})).await);
    let items = open["action_items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["item"]["task"], "Write release notes");
    let all = tool_json(&call("list_action_items", json!({ "open_only": false })).await);
    assert_eq!(all["action_items"].as_array().unwrap().len(), 2);

    let (_, resp) = rpc(&app, Some(&token), "resources/read", json!({ "uri": format!("flowstate://meetings/{id}") })).await;
    let md = resp["result"]["contents"][0]["text"].as_str().unwrap();
    assert!(md.contains("- [ ] Me: Write release notes (Thursday)\n- [x] Book room"), "{md}");

    let created = tool_json(&call("create_note", json!({ "title": "From Claude", "body": "Draft agenda" })).await);
    let note_id = created["id"].as_str().unwrap();
    let (status, note) = app.get(&format!("/v1/notes/{note_id}"), &token).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(note["source"], "mcp");
    assert_eq!(note["visibility"], "private");

    let missing = call("get_note", json!({ "id": uuid::Uuid::now_v7().to_string() })).await;
    assert_eq!(missing["result"]["isError"], true);
}
