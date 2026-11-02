use flowstate_mcp::{FlowstateServer, Store};
use rmcp::{
    handler::server::wrapper::Parameters,
    model::{CallToolRequestParams, ReadResourceRequestParams},
    ClientHandler, ServiceExt,
};
use rusqlite::Connection;
use serde_json::{json, Value};
use tempfile::TempDir;

use flowstate_mcp::server::*;

const MEETING_AT: i64 = 1_762_000_000; // 2025-11-01T12:26:40Z

struct Fixture {
    dir: TempDir,
}

fn fixture() -> Fixture {
    let dir = TempDir::new().unwrap();
    let n = Connection::open(dir.path().join("notes.db")).unwrap();
    n.execute_batch(
        "CREATE TABLE meetings(id INTEGER PRIMARY KEY, started_at INTEGER, ended_at INTEGER, title TEXT, calendar_event_id TEXT, participants_json TEXT, status TEXT, summary_md TEXT, action_items_json TEXT, raw_transcript_md TEXT);
         CREATE TABLE segments(id INTEGER PRIMARY KEY, meeting_id INTEGER, started_ms INTEGER, ended_ms INTEGER, speaker TEXT, raw TEXT, text TEXT);
         CREATE TABLE notes(id INTEGER PRIMARY KEY, created_at INTEGER, updated_at INTEGER, title TEXT, body_md TEXT, source TEXT, meeting_id INTEGER, tags_json TEXT, pinned INTEGER);
         CREATE VIRTUAL TABLE notes_fts USING fts5(title, body_md);
         CREATE VIRTUAL TABLE segments_fts USING fts5(text);
         CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN INSERT INTO notes_fts(rowid, title, body_md) VALUES (new.id, new.title, new.body_md); END;

         INSERT INTO meetings VALUES (1, 1762000000, 1762002700, 'Pricing sync', 'evt1', '[\"Ana\", {\"name\": \"Ben\"}]', 'done',
            'We agreed on the new tiers.\n\n- [ ] Draft the pricing page', NULL, NULL);
         INSERT INTO meetings VALUES (2, 1762100000, NULL, 'Roadmap', NULL, '[]', 'recording', NULL,
            '[{\"text\": \"Send roadmap deck\", \"owner\": \"Ana\", \"done\": false}, {\"text\": \"Book offsite\", \"done\": true}]', '[00:00:01] Ana: raw only transcript');
         INSERT INTO segments VALUES (1, 1, 3000, 6000, 'Ana', 'um the tiers look good', 'The tiers look good.');
         INSERT INTO segments VALUES (2, 1, 3725000, 3730000, 'Ben', 'ship it', 'Ship it on Monday.');
         INSERT INTO segments_fts(rowid, text) VALUES (1, 'The tiers look good.'), (2, 'Ship it on Monday.');
         INSERT INTO notes VALUES (1, 100, 300, 'Grocery list', 'milk, eggs and quasar-flour', 'manual', NULL, '[\"home\"]', 0);
         INSERT INTO notes VALUES (2, 100, 200, 'Pinned idea', 'Offline-first sync for tiers', 'dictation', 1, '[]', 1);",
    )
    .unwrap();
    let h = Connection::open(dir.path().join("history.db")).unwrap();
    h.execute_batch(
        "CREATE TABLE dictations(id INTEGER PRIMARY KEY, created_at INTEGER, app_id TEXT, raw TEXT, text TEXT, mode TEXT, duration_ms INTEGER);
         INSERT INTO dictations VALUES (1, 1000, 'com.apple.mail', 'um hi tiers team', 'Hi tiers team', 'local', 900);
         INSERT INTO dictations VALUES (2, 2000, 'com.tinyspeck.slackmacgap', 'ok done', 'OK, done.', 'local', 400);
         INSERT INTO dictations VALUES (3, 3000, 'com.apple.mail', 'thanks', 'Thanks.', 'local', 300);",
    )
    .unwrap();
    Fixture { dir }
}

fn server(f: &Fixture, allow_write: bool) -> FlowstateServer {
    FlowstateServer::new(Store::new(f.dir.path(), allow_write), allow_write)
}

fn parsed(r: Result<String, String>) -> Value {
    serde_json::from_str(&r.unwrap()).unwrap()
}

#[test]
fn search_spans_notes_segments_and_dictations() {
    let f = fixture();
    let s = server(&f, false);
    let v = parsed(s.search(Parameters(SearchArgs { query: "tiers".into(), limit: None })));
    let kinds: Vec<&str> = v["items"].as_array().unwrap().iter().map(|h| h["kind"].as_str().unwrap()).collect();
    assert!(kinds.contains(&"note") && kinds.contains(&"meeting_segment") && kinds.contains(&"dictation"), "{kinds:?}");
    let seg = v["items"].as_array().unwrap().iter().find(|h| h["kind"] == "meeting_segment").unwrap();
    assert_eq!(seg["title"], "Pricing sync");
    assert_eq!(seg["speaker"], "Ana");
    assert!(seg["snippet"].as_str().unwrap().contains("[tiers]"));
}

#[test]
fn search_prefix_limit_and_odd_input() {
    let f = fixture();
    let s = server(&f, false);
    let v = parsed(s.search(Parameters(SearchArgs { query: "quas".into(), limit: None })));
    assert_eq!(v["count"], 1);
    let v = parsed(s.search(Parameters(SearchArgs { query: "tiers".into(), limit: Some(2) })));
    assert_eq!(v["count"], 2);
    // FTS syntax characters must not blow up the query.
    let v = parsed(s.search(Parameters(SearchArgs { query: "\"tiers\" (".into(), limit: None })));
    assert!(v["count"].as_u64().unwrap() >= 1);
    let v = parsed(s.search(Parameters(SearchArgs { query: "%".into(), limit: None })));
    assert_eq!(v["count"], 0);
}

#[test]
fn notes_list_get_and_pinned() {
    let f = fixture();
    let s = server(&f, false);
    let v = parsed(s.list_notes(Parameters(ListNotesArgs { limit: None, pinned_only: None })));
    assert_eq!(v["items"][0]["title"], "Pinned idea");
    assert_eq!(v["items"][1]["preview"], "milk, eggs and quasar-flour");
    let v = parsed(s.list_notes(Parameters(ListNotesArgs { limit: None, pinned_only: Some(true) })));
    assert_eq!(v["count"], 1);
    let v = parsed(s.get_note(Parameters(IdArgs { id: 1 })));
    assert_eq!(v["body_md"], "milk, eggs and quasar-flour");
    assert_eq!(v["tags"], json!(["home"]));
    assert!(s.get_note(Parameters(IdArgs { id: 99 })).unwrap_err().contains("No note"));
}

#[test]
fn meetings_list_get_and_summary() {
    let f = fixture();
    let s = server(&f, false);
    let v = parsed(s.list_meetings(Parameters(ListMeetingsArgs { since_unix: None, limit: None })));
    assert_eq!(v["items"][0]["title"], "Roadmap");
    let v = parsed(s.list_meetings(Parameters(ListMeetingsArgs { since_unix: Some(MEETING_AT + 1), limit: None })));
    assert_eq!(v["count"], 1);

    let v = parsed(s.get_meeting(Parameters(GetMeetingArgs { id: 1, include_transcript: None })));
    assert_eq!(v["participants"], json!(["Ana", "Ben"]));
    assert_eq!(v["duration_minutes"], 45);
    assert!(v.get("transcript").is_none());
    assert_eq!(v["action_items"][0]["text"], "Draft the pricing page");

    let v = parsed(s.get_meeting(Parameters(GetMeetingArgs { id: 1, include_transcript: Some(true) })));
    assert_eq!(v["transcript"], "[00:00:03] Ana: The tiers look good.\n[01:02:05] Ben: Ship it on Monday.");

    let summary = s.get_meeting_summary(Parameters(IdArgs { id: 1 })).unwrap();
    assert!(summary.contains("new tiers"));
    assert_eq!(s.get_meeting_summary(Parameters(IdArgs { id: 2 })).unwrap(), "This meeting has no summary yet.");
    assert!(s.get_meeting_summary(Parameters(IdArgs { id: 9 })).is_err());
}

#[test]
fn action_items_open_only_and_all() {
    let f = fixture();
    let s = server(&f, false);
    let v = parsed(s.list_action_items(Parameters(ActionItemsArgs { open_only: None })));
    let texts: Vec<&str> = v["items"].as_array().unwrap().iter().map(|i| i["text"].as_str().unwrap()).collect();
    assert_eq!(texts, ["Send roadmap deck", "Draft the pricing page"]);
    assert_eq!(v["items"][0]["owner"], "Ana");
    let v = parsed(s.list_action_items(Parameters(ActionItemsArgs { open_only: Some(false) })));
    assert_eq!(v["count"], 3);
}

#[test]
fn dictations_recent_and_filtered() {
    let f = fixture();
    let s = server(&f, false);
    let v = parsed(s.recent_dictations(Parameters(DictationsArgs { limit: None, app_id: None })));
    assert_eq!(v["items"][0]["text"], "Thanks.");
    assert_eq!(v["items"][0]["raw"], "thanks");
    let v = parsed(s.recent_dictations(Parameters(DictationsArgs { limit: Some(1), app_id: Some("com.apple.mail".into()) })));
    assert_eq!(v["count"], 1);
    assert_eq!(v["items"][0]["id"], 3);
}

#[test]
fn export_markdown_layout() {
    let f = fixture();
    let s = server(&f, false);
    let md = s.export_meeting_markdown(Parameters(IdArgs { id: 1 })).unwrap();
    let expected = "# Pricing sync

**Date:** 2025-11-01 12:26 UTC (45 min)
**Participants:** Ana, Ben

## Summary

We agreed on the new tiers.

- [ ] Draft the pricing page

## Action items

- [ ] Draft the pricing page

## Transcript

[00:00:03] Ana: The tiers look good.
[01:02:05] Ben: Ship it on Monday.
";
    assert_eq!(md, expected);

    // No segments: falls back to the stored raw transcript.
    let md = s.export_meeting_markdown(Parameters(IdArgs { id: 2 })).unwrap();
    assert!(md.contains("- [ ] Send roadmap deck (Ana)") && md.contains("- [x] Book offsite"));
    assert!(md.ends_with("[00:00:01] Ana: raw only transcript\n"));
}

#[test]
fn missing_databases_read_as_empty() {
    let dir = TempDir::new().unwrap();
    let s = FlowstateServer::new(Store::new(dir.path(), false), false);
    let v = parsed(s.list_notes(Parameters(ListNotesArgs { limit: None, pinned_only: None })));
    assert_eq!(v["count"], 0);
    assert!(v["note"].as_str().unwrap().contains("No notes database"));
    let v = parsed(s.search(Parameters(SearchArgs { query: "anything".into(), limit: None })));
    assert_eq!(v["count"], 0);
    assert!(s.get_meeting(Parameters(GetMeetingArgs { id: 1, include_transcript: None })).is_err());
    let v = parsed(s.recent_dictations(Parameters(DictationsArgs { limit: None, app_id: None })));
    assert!(v["note"].as_str().unwrap().contains("No dictation history"));
}

#[test]
fn old_schema_without_tables_reads_as_empty() {
    let dir = TempDir::new().unwrap();
    Connection::open(dir.path().join("notes.db")).unwrap().execute_batch("CREATE TABLE unrelated(x)").unwrap();
    let s = FlowstateServer::new(Store::new(dir.path(), false), false);
    let v = parsed(s.search(Parameters(SearchArgs { query: "x".into(), limit: None })));
    assert_eq!(v["count"], 0);
    let v = parsed(s.list_meetings(Parameters(ListMeetingsArgs { since_unix: None, limit: None })));
    assert_eq!(v["count"], 0);
}

#[test]
fn create_note_requires_allow_write() {
    let f = fixture();
    let ro = server(&f, false);
    assert!(ro.create_note(Parameters(CreateNoteArgs { title: "t".into(), body: "b".into() })).is_err());

    let rw = server(&f, true);
    let msg = rw.create_note(Parameters(CreateNoteArgs { title: "From Claude".into(), body: "hello zebra".into() })).unwrap();
    assert_eq!(msg, "Created note 3");
    let v = parsed(rw.get_note(Parameters(IdArgs { id: 3 })));
    assert_eq!(v["source"], "mcp");
    let v = parsed(rw.search(Parameters(SearchArgs { query: "zebra".into(), limit: None })));
    assert_eq!(v["items"][0]["title"], "From Claude");
}

#[test]
fn read_only_connection_cannot_modify() {
    let f = fixture();
    let c = Connection::open_with_flags(f.dir.path().join("notes.db"), rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    assert!(c.execute("DELETE FROM notes", []).is_err());
}

#[derive(Clone)]
struct TestClient;
impl ClientHandler for TestClient {}

#[tokio::test]
async fn end_to_end_over_in_process_transport() {
    let f = fixture();
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    let server = server(&f, false);
    let server_task = tokio::spawn(async move { server.serve(server_io).await.unwrap().waiting().await });
    let client = TestClient.serve(client_io).await.unwrap();

    let info = client.peer_info().unwrap();
    assert!(info.instructions.as_deref().unwrap().contains("private"));

    let mut names: Vec<String> = client.list_all_tools().await.unwrap().into_iter().map(|t| t.name.to_string()).collect();
    names.sort();
    assert_eq!(
        names,
        [
            "export_meeting_markdown",
            "get_meeting",
            "get_meeting_summary",
            "get_note",
            "list_action_items",
            "list_meetings",
            "list_notes",
            "recent_dictations",
            "search"
        ]
    );

    let args = json!({"query": "tiers", "limit": 5}).as_object().unwrap().clone();
    let res = client.call_tool(CallToolRequestParams::new("search").with_arguments(args)).await.unwrap();
    assert_ne!(res.is_error, Some(true));
    let text = res.content[0].as_text().unwrap().text.clone();
    assert!(serde_json::from_str::<Value>(&text).unwrap()["count"].as_u64().unwrap() >= 3);

    let templates = client.list_all_resource_templates().await.unwrap();
    assert_eq!(templates.len(), 2);
    let r = client.read_resource(ReadResourceRequestParams::new("flowstate://meetings/1")).await.unwrap();
    assert!(format!("{:?}", r.contents).contains("# Pricing sync"));
    let r = client.read_resource(ReadResourceRequestParams::new("flowstate://notes/1")).await.unwrap();
    assert!(format!("{:?}", r.contents).contains("quasar-flour"));
    assert!(client.read_resource(ReadResourceRequestParams::new("flowstate://notes/77")).await.is_err());

    client.cancel().await.unwrap();
    let _ = server_task.await;
}

#[tokio::test]
async fn create_note_tool_listed_only_with_allow_write() {
    let f = fixture();
    let s = server(&f, true);
    let (server_io, client_io) = tokio::io::duplex(64 * 1024);
    tokio::spawn(async move { s.serve(server_io).await.unwrap().waiting().await });
    let client = TestClient.serve(client_io).await.unwrap();
    let names: Vec<String> = client.list_all_tools().await.unwrap().into_iter().map(|t| t.name.to_string()).collect();
    assert!(names.contains(&"create_note".to_string()));
    client.cancel().await.unwrap();
}
