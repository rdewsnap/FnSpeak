mod common;

use axum::http::StatusCode;
use common::{team_with_member, TestApp};
use serde_json::json;

#[tokio::test]
async fn members_share_snippets() {
    let app = TestApp::new().await;
    let (owner, member, team_id) = team_with_member(&app, "sn-owner@example.com", "sn-member@example.com").await;
    let path = format!("/v1/teams/{team_id}/snippets");

    // Any member can add one.
    let (status, added) = app.post(&path, &member, json!({ "trigger": "  Support   hours ", "text": "9 to 5, weekdays" })).await;
    assert_eq!(status, StatusCode::CREATED, "{added}");
    assert_eq!(added["trigger"], "Support hours");
    assert_eq!(added["text"], "9 to 5, weekdays");
    assert_eq!(added["team_name"], "Platform");
    assert_eq!(added["added_by"], "sn-member@example.com");
    assert_eq!(added["can_edit"], true);
    let id = added["id"].as_str().unwrap().to_string();

    // The same trigger in another case or with other punctuation is taken.
    let (status, _) = app.post(&path, &owner, json!({ "trigger": "support, HOURS", "text": "x" })).await;
    assert_eq!(status, StatusCode::CONFLICT);

    // The rules: two words, not a spoken command, sane lengths.
    for body in [
        json!({ "trigger": "hours", "text": "x" }),
        json!({ "trigger": "Send it", "text": "x" }),
        json!({ "trigger": "a ".repeat(40), "text": "x" }),
        json!({ "trigger": "status page", "text": "   " }),
        json!({ "trigger": "status page", "text": "x".repeat(4001) }),
    ] {
        assert_eq!(app.post(&path, &owner, body.clone()).await.0, StatusCode::BAD_REQUEST, "{body}");
    }

    let (_, owned) = app.post(&path, &owner, json!({ "trigger": "status page", "text": "status.example.com" })).await;
    let owned_id = owned["id"].as_str().unwrap().to_string();

    // Everyone on the team sees both; can_edit is per caller.
    let (_, mine) = app.get("/v1/snippets", &member).await;
    let list = mine["snippets"].as_array().unwrap();
    assert_eq!(list.iter().map(|s| s["trigger"].as_str().unwrap()).collect::<Vec<_>>(), vec!["status page", "Support hours"]);
    assert_eq!(list[0]["can_edit"], false);
    assert_eq!(list[1]["can_edit"], true);
    let (_, theirs) = app.get(&path, &owner).await;
    assert!(theirs["snippets"].as_array().unwrap().iter().all(|s| s["can_edit"] == true));

    // A member can't change or remove someone else's; an owner can.
    let owned_path = format!("{path}/{owned_id}");
    let edit = json!({ "text": "nope" });
    assert_eq!(app.call("PATCH", &owned_path, Some(&member), Some(edit)).await.0, StatusCode::FORBIDDEN);
    assert_eq!(app.call("DELETE", &owned_path, Some(&member), None).await.0, StatusCode::FORBIDDEN);

    let mine_path = format!("{path}/{id}");
    let (status, changed) = app.call("PATCH", &mine_path, Some(&owner), Some(json!({ "text": "9 to 6" }))).await;
    assert_eq!(status, StatusCode::OK, "{changed}");
    assert_eq!((changed["trigger"].as_str(), changed["text"].as_str()), (Some("Support hours"), Some("9 to 6")));
    // Renaming onto the other snippet's trigger is a conflict.
    let rename = json!({ "trigger": "Status Page" });
    assert_eq!(app.call("PATCH", &mine_path, Some(&member), Some(rename)).await.0, StatusCode::CONFLICT);
    assert_eq!(app.call("DELETE", &mine_path, Some(&member), None).await.0, StatusCode::NO_CONTENT);
    assert_eq!(app.call("DELETE", &mine_path, Some(&member), None).await.0, StatusCode::NOT_FOUND);

    // Outsiders see nothing and can't probe the team.
    let outsider = app.sign_in("sn-outsider@example.com").await;
    assert_eq!(app.get(&path, &outsider).await.0, StatusCode::NOT_FOUND);
    assert_eq!(app.post(&path, &outsider, json!({ "trigger": "status board", "text": "x" })).await.0, StatusCode::NOT_FOUND);
    let (_, none) = app.get("/v1/snippets", &outsider).await;
    assert!(none["snippets"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn one_user_in_two_teams_keeps_their_snippets_apart() {
    let app = TestApp::new().await;
    let user = app.sign_in("sn-two@example.com").await;
    let mut teams = Vec::new();
    for name in ["Alpha", "Beta"] {
        let (status, team) = app.post("/v1/teams", &user, json!({ "name": name })).await;
        assert_eq!(status, StatusCode::CREATED, "{team}");
        teams.push(team["id"].as_str().unwrap().to_string());
    }
    let (a_path, b_path) = (format!("/v1/teams/{}/snippets", teams[0]), format!("/v1/teams/{}/snippets", teams[1]));
    let (status, a) = app.post(&a_path, &user, json!({ "trigger": "alpha handbook", "text": "alpha text" })).await;
    assert_eq!(status, StatusCode::CREATED, "{a}");
    let (status, b) = app.post(&b_path, &user, json!({ "trigger": "beta handbook", "text": "beta text" })).await;
    assert_eq!(status, StatusCode::CREATED, "{b}");
    let a_id = a["id"].as_str().unwrap().to_string();

    // The combined list has both, each under its own team's name.
    let (_, all) = app.get("/v1/snippets", &user).await;
    let list = all["snippets"].as_array().unwrap();
    assert_eq!(list.len(), 2, "{all}");
    let team_of = |trigger: &str| list.iter().find(|s| s["trigger"] == trigger).unwrap()["team_name"].clone();
    assert_eq!(team_of("alpha handbook"), "Alpha");
    assert_eq!(team_of("beta handbook"), "Beta");

    // Team A's snippet can't be reached through team B's path.
    let wrong = format!("{b_path}/{a_id}");
    assert_eq!(app.call("PATCH", &wrong, Some(&user), Some(json!({ "text": "hijacked" }))).await.0, StatusCode::NOT_FOUND);
    assert_eq!(app.call("DELETE", &wrong, Some(&user), None).await.0, StatusCode::NOT_FOUND);
    let (_, after) = app.get(&a_path, &user).await;
    let kept = after["snippets"].as_array().unwrap();
    assert_eq!(kept.len(), 1);
    assert_eq!((kept[0]["trigger"].as_str(), kept[0]["text"].as_str()), (Some("alpha handbook"), Some("alpha text")));

    // Edits go through the same rules as adding.
    let right = format!("{a_path}/{a_id}");
    assert_eq!(app.call("PATCH", &right, Some(&user), Some(json!({ "trigger": "handbook" }))).await.0, StatusCode::BAD_REQUEST);
    assert_eq!(app.call("PATCH", &right, Some(&user), Some(json!({ "text": "   " }))).await.0, StatusCode::BAD_REQUEST);
}
