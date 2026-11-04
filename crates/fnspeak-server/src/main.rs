use fnspeak_server::{mail::Mailer, AppState, Config};
use tracing_subscriber::EnvFilter;

const USAGE: &str = "usage:
  fnspeak-server                          run the server (configured by FNSPEAK_* env vars)";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info,tower_http=info"));
    if std::env::var("FNSPEAK_LOG_FORMAT").is_ok_and(|f| f == "json") {
        tracing_subscriber::fmt().with_env_filter(filter).json().init();
    } else {
        tracing_subscriber::fmt().with_env_filter(filter).init();
    }

    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        [] | ["serve"] => serve().await,
        _ => {
            eprintln!("{USAGE}");
            std::process::exit(2);
        }
    }
}

async fn serve() -> anyhow::Result<()> {
    let config = Config::from_env()?;
    let mailer = Mailer::from_config(config.smtp.as_ref())?;
    if config.smtp.is_none() {
        tracing::warn!("FNSPEAK_SMTP_HOST not set: sign-in links will be logged instead of emailed");
    }
    if config.llm.is_none() {
        tracing::info!("FNSPEAK_LLM_API_KEY not set: hosted cleanup and summaries are off");
    }
    let state = AppState::new(config, mailer).await?;
    fnspeak_server::serve(state).await
}
