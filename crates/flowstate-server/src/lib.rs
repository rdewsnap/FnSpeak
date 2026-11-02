//! Flowstate's optional backend: accounts and teams, note and meeting sync,
//! a shared team glossary, hosted cleanup, and an MCP endpoint so AI
//! assistants can read what you've dictated. The app works fully without it.

pub mod auth;
pub mod config;
pub mod db;
pub mod error;
pub mod glossary;
pub mod mail;
pub mod mcp;
pub mod ratelimit;
pub mod store;
pub mod sync;
pub mod teams;

use axum::extract::{DefaultBodyLimit, MatchedPath};
use axum::http::{header, HeaderName, HeaderValue, Method, Request};
use axum::routing::{delete, get, patch, post};
use axum::{Json, Router};
use serde_json::json;
use std::sync::Arc;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

pub use config::Config;
use db::Db;
use mail::Mailer;
use ratelimit::RateLimiter;

const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub config: Arc<Config>,
    pub mailer: Mailer,
    pub limiter: Arc<RateLimiter>,
}

impl AppState {
    pub async fn new(config: Config, mailer: Mailer) -> anyhow::Result<AppState> {
        let db = Db::connect(&config.database_url).await?;
        Ok(AppState { db, config: Arc::new(config), mailer, limiter: Arc::new(RateLimiter::default()) })
    }
}

pub fn router(state: AppState) -> Router {
    let api = Router::new()
        .route("/v1/auth/magic-link", post(auth::request_link))
        .route("/v1/auth/verify", get(auth::verify_page).post(auth::verify))
        .route("/v1/me", get(auth::me))
        .route("/v1/tokens", get(auth::list_tokens).post(auth::create_token))
        .route("/v1/tokens/{id}", delete(auth::delete_token))
        .route("/v1/teams", get(teams::list).post(teams::create))
        .route("/v1/teams/{id}", get(teams::get).patch(teams::update))
        .route("/v1/teams/{id}/invites", get(teams::list_invites).post(teams::invite))
        .route("/v1/teams/{id}/invites/{invite_id}", delete(teams::revoke_invite))
        .route("/v1/teams/{id}/members/{user_id}", patch(teams::set_role).delete(teams::remove_member))
        .route("/v1/teams/{id}/glossary", get(glossary::list).post(glossary::add))
        .route("/v1/teams/{id}/glossary/{term_id}", delete(glossary::remove))
        .route("/v1/glossary", get(glossary::mine))
        .route("/v1/invites/{token}", get(teams::show_invite))
        .route("/v1/invites/{token}/accept", post(teams::accept_invite))
        .route("/v1/notes", get(sync::list_notes))
        .route("/v1/notes/{id}", get(sync::get_note).put(sync::put_note).delete(sync::delete_note))
        .route("/v1/meetings", get(sync::list_meetings))
        .route("/v1/meetings/{id}", get(sync::get_meeting).put(sync::put_meeting).delete(sync::delete_meeting))
        .route("/v1/sync", get(sync::pull).post(sync::push))
        .route("/v1/search", get(sync::search));

    let mcp = Router::new()
        .route_service("/mcp", mcp::service(state.clone()))
        .route_layer(axum::middleware::from_fn_with_state(state.clone(), mcp::require_token));

    Router::new()
        .route("/healthz", get(healthz))
        .merge(api)
        .merge(mcp)
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .layer(cors(&state.config))
        // Log the route pattern, not the URI: paths and query strings can
        // carry sign-in and invite tokens.
        .layer(TraceLayer::new_for_http().make_span_with(|req: &Request<_>| {
            let route = req.extensions().get::<MatchedPath>().map(MatchedPath::as_str).unwrap_or("-");
            tracing::info_span!("request", method = %req.method(), route = %route)
        }))
        .with_state(state)
}

async fn healthz(axum::extract::State(state): axum::extract::State<AppState>) -> Json<serde_json::Value> {
    let db_ok = state.db.query("SELECT 1", vec![]).await.is_ok();
    Json(json!({ "status": if db_ok { "ok" } else { "degraded" }, "version": env!("CARGO_PKG_VERSION") }))
}

fn cors(config: &Config) -> CorsLayer {
    let origins: Vec<HeaderValue> = config.cors_origins.iter().filter_map(|o| o.parse().ok()).collect();
    CorsLayer::new()
        .allow_origin(origins)
        .allow_methods([Method::GET, Method::POST, Method::PUT, Method::PATCH, Method::DELETE])
        .allow_headers([
            header::AUTHORIZATION,
            header::CONTENT_TYPE,
            HeaderName::from_static("mcp-session-id"),
            HeaderName::from_static("mcp-protocol-version"),
        ])
}

/// Serve until Ctrl-C or SIGTERM, then finish in-flight requests.
pub async fn serve(state: AppState) -> anyhow::Result<()> {
    let listener = tokio::net::TcpListener::bind(&state.config.bind).await?;
    tracing::info!(addr = %listener.local_addr()?, base_url = %state.config.base_url, "listening");
    let app = router(state).into_make_service_with_connect_info::<std::net::SocketAddr>();
    axum::serve(listener, app).with_graceful_shutdown(shutdown_signal()).await?;
    tracing::info!("shut down");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {},
        _ = term => {},
    }
}
