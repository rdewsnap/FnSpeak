mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::routing::post;
use axum::{Json, Router};
use common::TestApp;
use fnspeak_server::config::GoogleConfig;
use fnspeak_server::Config;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

const CLIENT_ID: &str = "client-123.apps.googleusercontent.com";

fn base64url(data: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let n = chunk.iter().fold(0u32, |n, b| (n << 8) | u32::from(*b)) << (8 * (3 - chunk.len()));
        for i in 0..=chunk.len() {
            out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    out
}

fn id_token(claims: Value) -> String {
    format!("{}.{}.sig", base64url(b"{\"alg\":\"RS256\"}"), base64url(claims.to_string().as_bytes()))
}

fn claims(email: &str) -> Value {
    json!({ "iss": "https://accounts.google.com", "aud": CLIENT_ID, "email": email, "email_verified": true, "exp": 4_102_444_800i64 })
}

/// A stand-in for Google's token endpoint. It hands out whatever ID token
/// the test put in `next`, and records the form it was sent.
async fn fake_google(next: Arc<Mutex<Value>>, seen: Arc<Mutex<Vec<String>>>) -> String {
    let app = Router::new().route(
        "/token",
        post(move |body: String| {
            let (next, seen) = (next.clone(), seen.clone());
            async move {
                seen.lock().unwrap().push(body);
                Json(json!({ "access_token": "ya29.x", "id_token": id_token(next.lock().unwrap().clone()) }))
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    format!("http://{addr}/token")
}

struct Setup {
    app: TestApp,
    next: Arc<Mutex<Value>>,
    seen: Arc<Mutex<Vec<String>>>,
}

async fn setup() -> Setup {
    let next = Arc::new(Mutex::new(claims("ana@example.com")));
    let seen = Arc::default();
    let token_url = fake_google(next.clone(), Arc::clone(&seen)).await;
    let mut config = Config::for_tests();
    config.google = Some(GoogleConfig {
        client_id: CLIENT_ID.into(),
        client_secret: "shh".into(),
        auth_url: "https://accounts.google.test/auth".into(),
        token_url,
    });
    Setup { app: TestApp::with_config(config).await, next, seen }
}

/// What the app does: keep the verifier, show the browser only its hash.
fn pair(seed: &str) -> (String, String) {
    let verifier = format!("fsg_{seed}");
    let challenge = hex::encode(Sha256::digest(verifier.as_bytes()));
    (verifier, challenge)
}

async fn get(app: &TestApp, path: &str) -> (StatusCode, Option<String>, String) {
    let req = Request::builder().uri(path).header("host", "localhost:8080").body(Body::empty()).unwrap();
    let resp = app.router.clone().oneshot(req).await.unwrap();
    let status = resp.status();
    let location = resp.headers().get("location").map(|l| l.to_str().unwrap().to_string());
    let bytes = http_body_util::BodyExt::collect(resp.into_body()).await.unwrap().to_bytes();
    (status, location, String::from_utf8_lossy(&bytes).into())
}

async fn claim(app: &TestApp, verifier: &str) -> (StatusCode, Value) {
    app.call("POST", "/v1/auth/verify", None, Some(json!({ "token": verifier, "name": "Test Mac" }))).await
}

#[tokio::test]
async fn google_sign_in_ends_with_the_app_holding_a_token() {
    let s = setup().await;
    let (verifier, challenge) = pair("a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2");

    let (_, _, providers) = get(&s.app, "/v1/auth/providers").await;
    assert_eq!(serde_json::from_str::<Value>(&providers).unwrap()["google"], true);

    // The browser is sent to Google with the challenge as state.
    let (status, location, _) = get(&s.app, &format!("/v1/auth/google?challenge={challenge}")).await;
    assert_eq!(status, StatusCode::SEE_OTHER);
    let location = location.unwrap();
    assert!(location.starts_with("https://accounts.google.test/auth?response_type=code&client_id=client-123.apps.googleusercontent.com"));
    assert!(location.contains("redirect_uri=http%3A%2F%2Flocalhost%3A8080%2Fv1%2Fauth%2Fgoogle%2Fcallback"));
    assert!(location.contains("scope=openid%20email"));
    assert!(location.contains(&format!("state={challenge}")));

    // Nothing to collect until Google has answered.
    assert_eq!(claim(&s.app, &verifier).await.0, StatusCode::BAD_REQUEST);

    let (status, _, page) = get(&s.app, &format!("/v1/auth/google/callback?code=4%2Fabc&state={challenge}")).await;
    assert_eq!(status, StatusCode::OK);
    assert!(page.contains("Signed in as ana@example.com"));
    assert!(page.contains("fnspeak://signin"));
    // The page hands the browser nothing that could sign anyone in.
    assert!(!page.contains("fst_") && !page.contains("fsl_") && !page.contains(&verifier));
    {
        let seen = s.seen.lock().unwrap();
        assert!(seen[0].contains("grant_type=authorization_code"));
        assert!(seen[0].contains("code=4%2Fabc"));
        assert!(seen[0].contains("client_secret=shh"));
    }

    // Knowing the challenge isn't enough; only the verifier collects it.
    assert_eq!(claim(&s.app, &format!("fsg_{challenge}")).await.0, StatusCode::BAD_REQUEST);
    let (status, body) = claim(&s.app, &verifier).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["user"]["email"], "ana@example.com");
    let token = body["token"].as_str().unwrap();
    assert_eq!(s.app.get("/v1/me", token).await.1["user"]["email"], "ana@example.com");

    // Once only.
    assert_eq!(claim(&s.app, &verifier).await.0, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn the_same_email_is_the_same_account_however_they_sign_in() {
    let s = setup().await;
    let by_link = s.app.sign_in("ana@example.com").await;
    let (verifier, challenge) = pair("b1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2");
    *s.next.lock().unwrap() = claims("Ana@Example.com");
    get(&s.app, &format!("/v1/auth/google/callback?code=x&state={challenge}")).await;
    let by_google = claim(&s.app, &verifier).await.1["token"].as_str().unwrap().to_string();
    let id = |me: Value| me["user"]["id"].as_str().unwrap().to_string();
    assert_eq!(id(s.app.get("/v1/me", &by_link).await.1), id(s.app.get("/v1/me", &by_google).await.1));
}

#[tokio::test]
async fn bad_answers_from_google_sign_nobody_in() {
    let s = setup().await;
    let cases = [
        ("an unverified address", json!({ "iss": "https://accounts.google.com", "aud": CLIENT_ID, "email": "x@example.com", "email_verified": false, "exp": 4_102_444_800i64 })),
        ("a token for another app", json!({ "iss": "https://accounts.google.com", "aud": "someone-else", "email": "x@example.com", "email_verified": true, "exp": 4_102_444_800i64 })),
        ("another issuer", json!({ "iss": "https://evil.example", "aud": CLIENT_ID, "email": "x@example.com", "email_verified": true, "exp": 4_102_444_800i64 })),
        ("an expired token", json!({ "iss": "https://accounts.google.com", "aud": CLIENT_ID, "email": "x@example.com", "email_verified": true, "exp": 1_000_000_000i64 })),
    ];
    for (i, (what, bad)) in cases.into_iter().enumerate() {
        let (verifier, challenge) = pair(&format!("c{i}b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"));
        *s.next.lock().unwrap() = bad;
        let (status, _, page) = get(&s.app, &format!("/v1/auth/google/callback?code=x&state={challenge}")).await;
        assert_eq!(status, StatusCode::OK, "{what}");
        assert!(page.contains("That didn't work"), "{what}: {page}");
        assert!(!page.contains("fnspeak://signin"), "{what}");
        assert_eq!(claim(&s.app, &verifier).await.0, StatusCode::BAD_REQUEST, "{what}");
    }

    // Cancelling at Google, or a mangled link, ends the same way.
    let (_, _, page) = get(&s.app, "/v1/auth/google/callback?error=access_denied").await;
    assert!(page.contains("cancelled"));
    let (_, _, page) = get(&s.app, "/v1/auth/google/callback?code=x&state=not-a-challenge").await;
    assert!(page.contains("incomplete"));
    assert_eq!(get(&s.app, "/v1/auth/google?challenge=short").await.0, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn servers_without_a_google_client_dont_offer_it() {
    let app = TestApp::new().await;
    let (_, _, providers) = get(&app, "/v1/auth/providers").await;
    assert_eq!(serde_json::from_str::<Value>(&providers).unwrap()["google"], false);
    let challenge = "a".repeat(64);
    assert_eq!(get(&app, &format!("/v1/auth/google?challenge={challenge}")).await.0, StatusCode::NOT_FOUND);
    let (_, _, page) = get(&app, &format!("/v1/auth/google/callback?code=x&state={challenge}")).await;
    assert!(page.contains("doesn't offer Google sign-in"));
}
