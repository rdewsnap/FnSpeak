//! Configuration, read from `FLOWSTATE_*` environment variables.

use anyhow::{bail, Context};
use std::env;

#[derive(Clone, Debug)]
pub struct Config {
    pub bind: String,
    pub database_url: String,
    /// Public URL of this server, used to build links in emails.
    pub base_url: String,
    /// Mixed into every stored token hash, so a leaked database alone can't
    /// be used to check guessed tokens.
    pub secret: String,
    pub smtp: Option<SmtpConfig>,
    /// Origins allowed to call the API from a browser.
    pub cors_origins: Vec<String>,
    /// Use the first `X-Forwarded-For` address for rate limiting. Only set
    /// this behind a proxy that overwrites the header.
    pub trust_proxy: bool,
}

#[derive(Clone, Debug)]
pub struct SmtpConfig {
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub password: Option<String>,
    pub from: String,
    /// `starttls` (default), `tls` or `none`.
    pub security: String,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Config> {
        let base_url = var("FLOWSTATE_BASE_URL").unwrap_or_else(|| "http://localhost:8080".into());
        let secret = match var("FLOWSTATE_SECRET") {
            Some(s) if s.len() >= 32 => s,
            Some(_) => bail!("FLOWSTATE_SECRET must be at least 32 characters"),
            None => bail!("FLOWSTATE_SECRET is not set; generate one with `openssl rand -hex 32`"),
        };
        let smtp = match var("FLOWSTATE_SMTP_HOST") {
            Some(host) => Some(SmtpConfig {
                host,
                port: var("FLOWSTATE_SMTP_PORT")
                    .map(|p| p.parse())
                    .transpose()
                    .context("FLOWSTATE_SMTP_PORT")?
                    .unwrap_or(587),
                username: var("FLOWSTATE_SMTP_USERNAME"),
                password: var("FLOWSTATE_SMTP_PASSWORD"),
                from: var("FLOWSTATE_SMTP_FROM").context("FLOWSTATE_SMTP_FROM is required with FLOWSTATE_SMTP_HOST")?,
                security: var("FLOWSTATE_SMTP_SECURITY").unwrap_or_else(|| "starttls".into()),
            }),
            None => None,
        };
        let cors_origins = match var("FLOWSTATE_CORS_ORIGINS") {
            Some(list) => list.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect(),
            None => vec![origin_of(&base_url)],
        };
        Ok(Config {
            bind: var("FLOWSTATE_BIND").unwrap_or_else(|| "0.0.0.0:8080".into()),
            database_url: var("FLOWSTATE_DATABASE_URL").unwrap_or_else(|| "sqlite://flowstate.db".into()),
            base_url: base_url.trim_end_matches('/').to_string(),
            secret,
            smtp,
            cors_origins,
            trust_proxy: var("FLOWSTATE_TRUST_PROXY").is_some_and(|v| v == "1" || v == "true"),
        })
    }

    /// Defaults for tests and local experiments: in-memory SQLite, links
    /// logged instead of emailed.
    pub fn for_tests() -> Config {
        Config {
            bind: "127.0.0.1:0".into(),
            database_url: "sqlite::memory:".into(),
            base_url: "http://localhost:8080".into(),
            secret: "test-secret-test-secret-test-secret".into(),
            smtp: None,
            cors_origins: vec!["http://localhost:8080".into()],
            trust_proxy: false,
        }
    }
}

fn var(name: &str) -> Option<String> {
    env::var(name).ok().filter(|v| !v.trim().is_empty())
}

/// `https://example.com/path` → `https://example.com`.
pub fn origin_of(url: &str) -> String {
    match url.find("://") {
        Some(i) => {
            let rest = &url[i + 3..];
            let end = rest.find('/').map(|j| i + 3 + j).unwrap_or(url.len());
            url[..end].to_string()
        }
        None => url.to_string(),
    }
}

/// `https://example.com:8443/x` → `example.com`.
pub fn host_of(url: &str) -> String {
    let origin = origin_of(url);
    let authority = origin.split("://").nth(1).unwrap_or(&origin);
    authority.split(':').next().unwrap_or(authority).to_string()
}
