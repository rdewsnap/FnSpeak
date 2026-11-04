//! MCP server that lets AI tools read the user's FnSpeak notes, meetings and
//! dictation history. Local stdio only; the databases are opened read-only.

use anyhow::Result;
use clap::Parser;
use fnspeak_mcp::{FnSpeakServer, Store};
use rmcp::{transport::stdio, ServiceExt};
use std::path::PathBuf;

#[derive(Parser)]
#[command(version, about = "Expose FnSpeak notes, meetings and dictations to MCP clients over stdio (read-only)")]
struct Args {
    /// Folder holding notes.db and history.db [default: ~/Library/Application Support/FnSpeak]
    #[arg(long)]
    data_dir: Option<PathBuf>,
    /// Also offer a create_note tool (opens notes.db read-write)
    #[arg(long)]
    allow_write: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let dir = args
        .data_dir
        .or_else(|| dirs::data_dir().map(|d| d.join("FnSpeak")))
        .ok_or_else(|| anyhow::anyhow!("can't locate the data directory; pass --data-dir"))?;
    let server = FnSpeakServer::new(Store::new(dir, args.allow_write), args.allow_write);
    server.serve(stdio()).await?.waiting().await?;
    Ok(())
}
