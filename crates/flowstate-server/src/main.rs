use flowstate_server::{mail::Mailer, AppState, Config};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info,tower_http=info"));
    if std::env::var("FLOWSTATE_LOG_FORMAT").is_ok_and(|f| f == "json") {
        tracing_subscriber::fmt().with_env_filter(filter).json().init();
    } else {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    }

    let config = Config::from_env()?;
    let mailer = Mailer::from_config(config.smtp.as_ref())?;
    if config.smtp.is_none() {
        tracing::warn!("FLOWSTATE_SMTP_HOST not set: sign-in links will be logged instead of emailed");
    }
    let state = AppState::new(config, mailer).await?;
    flowstate_server::serve(state).await
}
