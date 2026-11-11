//! Local cleanup through llama.cpp's `llama-server`, run as a child process
//! bound to localhost (Metal on Mac, CUDA/Vulkan builds on Windows).
//!
//! It runs out of process on purpose: whisper.cpp and llama.cpp each bundle
//! their own copy of ggml, and linking both into one binary gives duplicate
//! symbols. A sidecar also keeps a model crash from taking down the app and
//! lets the app free the model's memory by stopping the process.

use super::{Cleaner, CleanupError, CleanupRequest, Llm, OpenAiCompatCleaner};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, sleep, JoinHandle};
use std::time::{Duration, Instant};

/// After this long without a request, send a tiny one so Metal doesn't drop
/// to a low-power state and the next dictation doesn't pay for it. The first
/// dictation after a few idle minutes was running 500-800 ms against ~300 ms
/// when warm.
const KEEP_WARM_AFTER: Duration = Duration::from_secs(120);
/// The ping is one token of output; give up quickly if the server is busy.
const KEEP_WARM_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Debug)]
pub struct LocalConfig {
    /// The `llama-server` binary (bundled in the app, or from Homebrew).
    pub server_binary: PathBuf,
    /// A GGUF instruction-tuned model: a 3–4B Qwen or Gemma at Q4_K_M, or
    /// the FnSpeak fine-tune.
    pub model_path: PathBuf,
    pub context_tokens: u32,
    pub gpu_layers: u32,
    /// Give up on a dictation and fall back to the rule-based output after this long.
    pub timeout: Duration,
    /// How long the model may take to load at startup.
    pub load_timeout: Duration,
}

impl LocalConfig {
    pub fn new(server_binary: impl Into<PathBuf>, model_path: impl Into<PathBuf>) -> Self {
        LocalConfig {
            server_binary: server_binary.into(),
            model_path: model_path.into(),
            context_tokens: 4096,
            gpu_layers: 999,
            timeout: Duration::from_secs(6),
            load_timeout: Duration::from_secs(90),
        }
    }
}

pub struct LlamaServer {
    child: Child,
    pub base_url: String,
}

impl LlamaServer {
    pub fn start(config: &LocalConfig) -> Result<Self, CleanupError> {
        for (what, path) in [("llama-server", &config.server_binary), ("cleanup model", &config.model_path)] {
            if !path.exists() {
                return Err(CleanupError::Load(format!("{what} not found at {}", path.display())));
            }
        }
        reap_orphans(config);
        let port = free_port()?;
        let mut child = Command::new(&config.server_binary)
            .arg("--model")
            .arg(&config.model_path)
            .args(["--host", "127.0.0.1", "--port", &port.to_string()])
            .args(["--ctx-size", &config.context_tokens.to_string()])
            .args(["--n-gpu-layers", &config.gpu_layers.to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| CleanupError::Load(format!("couldn't start llama-server: {e}")))?;

        let base_url = format!("http://127.0.0.1:{port}");
        let health = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(2))
            .build()
            .map_err(|e| CleanupError::Load(e.to_string()))?;
        let started = Instant::now();
        loop {
            if let Ok(Some(status)) = child.try_wait() {
                return Err(CleanupError::Load(format!("llama-server exited during startup ({status})")));
            }
            // /health returns 503 while the model is still loading.
            if health.get(format!("{base_url}/health")).send().is_ok_and(|r| r.status().is_success()) {
                break;
            }
            if started.elapsed() > config.load_timeout {
                let _ = child.kill();
                return Err(CleanupError::Load("llama-server didn't become ready in time".into()));
            }
            sleep(Duration::from_millis(200));
        }
        Ok(LlamaServer { child, base_url })
    }
}

impl Drop for LlamaServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Stop servers left running by a copy of the app that crashed or was force
/// quit. Each holds a few GB of memory, and nothing else will ever stop them.
fn reap_orphans(config: &LocalConfig) {
    let Ok(out) = Command::new("/bin/ps").args(["-axo", "pid=,ppid=,command="]).output() else { return };
    let listing = String::from_utf8_lossy(&out.stdout);
    for pid in orphans(&listing, &config.server_binary, config.model_path.parent()) {
        // llama-server ignores a plain TERM while it's serving.
        let _ = Command::new("/bin/kill").args(["-9", &pid.to_string()]).status();
    }
}

/// From `ps -axo pid=,ppid=,command=`: llama-servers whose parent is gone
/// (adopted by launchd) and that are ours, going by the binary they run or
/// the folder their model is in.
fn orphans(ps: &str, server_binary: &std::path::Path, models_dir: Option<&std::path::Path>) -> Vec<u32> {
    // ps pads its columns, so compare with runs of spaces collapsed.
    let squash = |p: &std::path::Path| p.to_string_lossy().split_whitespace().collect::<Vec<_>>().join(" ");
    let binary = squash(server_binary);
    let models = models_dir.map(squash).filter(|m| !m.is_empty());
    ps.lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let pid: u32 = fields.next()?.parse().ok()?;
            let ppid: u32 = fields.next()?.parse().ok()?;
            let command = fields.collect::<Vec<_>>().join(" ");
            let ours = command.starts_with(&binary) || models.as_ref().is_some_and(|m| command.contains(&format!("--model {m}/")));
            (ppid == 1 && command.contains("llama-server") && ours).then_some(pid)
        })
        .collect()
}

fn free_port() -> Result<u16, CleanupError> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| CleanupError::Load(e.to_string()))?;
    listener.local_addr().map(|a| a.port()).map_err(|e| CleanupError::Load(e.to_string()))
}

/// A cleaner backed by its own `llama-server`. The server stops when this is dropped.
pub struct LocalCleaner {
    inner: OpenAiCompatCleaner,
    model_name: String,
    last_used: Arc<Mutex<Instant>>,
    _keep_warm: KeepWarm,
    // Declared last so the client and the keep-warm thread are dropped before
    // the server stops.
    _server: LlamaServer,
}

impl LocalCleaner {
    pub fn start(config: LocalConfig) -> Result<Self, CleanupError> {
        let server = LlamaServer::start(&config)?;
        let model_name = file_name(&config.model_path);
        let inner = OpenAiCompatCleaner::new(format!("{}/v1", server.base_url), None, model_name.clone())?
            .with_prompt_cache()
            .with_timeout(config.timeout)?
            .with_context_tokens(config.context_tokens as usize);
        let last_used = Arc::new(Mutex::new(Instant::now()));
        let keep_warm = KeepWarm::spawn(inner.clone(), last_used.clone());
        Ok(LocalCleaner { inner, model_name, last_used, _keep_warm: keep_warm, _server: server })
    }
}

/// Background thread that pings the server while the cleaner sits idle.
/// Dropping it stops and joins the thread.
struct KeepWarm {
    // Dropping the sender wakes the thread with `Disconnected`.
    stop: Option<Sender<()>>,
    thread: Option<JoinHandle<()>>,
}

impl KeepWarm {
    fn spawn(client: OpenAiCompatCleaner, last_used: Arc<Mutex<Instant>>) -> Self {
        let (stop, rx) = mpsc::channel::<()>();
        let thread = thread::spawn(move || loop {
            let idle = last_used.lock().unwrap_or_else(|e| e.into_inner()).elapsed();
            let wait = KEEP_WARM_AFTER.saturating_sub(idle);
            match rx.recv_timeout(wait.max(Duration::from_secs(1))) {
                Err(RecvTimeoutError::Timeout) => {}
                // Stopped, or nobody left to stop us.
                _ => return,
            }
            let idle = last_used.lock().unwrap_or_else(|e| e.into_inner()).elapsed();
            if idle >= KEEP_WARM_AFTER {
                client.warm(KEEP_WARM_TIMEOUT);
                *last_used.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
            }
        });
        KeepWarm { stop: Some(stop), thread: Some(thread) }
    }
}

impl Drop for KeepWarm {
    fn drop(&mut self) {
        self.stop.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Cleaner for LocalCleaner {
    fn name(&self) -> String {
        format!("local:{}", self.model_name)
    }

    fn clean(&mut self, req: &CleanupRequest<'_>) -> Result<String, CleanupError> {
        *self.last_used.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
        let result = self.inner.clean(req);
        *self.last_used.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
        result
    }

    /// Talks to this cleaner's own server, so summaries reuse the loaded
    /// model instead of starting a second one.
    fn llm(&self) -> Option<Box<dyn Llm>> {
        self.inner.llm()
    }
}

fn file_name(path: &Path) -> String {
    path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keep_warm_stops_promptly_on_drop() {
        let client = OpenAiCompatCleaner::new("http://127.0.0.1:9/v1", None, "test").unwrap();
        let started = Instant::now();
        drop(KeepWarm::spawn(client, Arc::new(Mutex::new(Instant::now()))));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn finds_only_our_orphaned_servers() {
        let ps = "\
  101     1 /Applications/FnSpeak.app/Contents/Resources/llama-server --model /Users/me/Library/Application Support/FnSpeak/Models/a.gguf --port 1
  102   900 /Applications/FnSpeak.app/Contents/Resources/llama-server --model /Users/me/Library/Application Support/FnSpeak/Models/a.gguf --port 2
  103     1 /opt/homebrew/bin/llama-server --model /Users/me/other/b.gguf
  104     1 /old/build/llama-server --model /Users/me/Library/Application Support/FnSpeak/Models/a.gguf
  105     1 /usr/bin/something --model /Users/me/Library/Application Support/FnSpeak/Models/a.gguf
";
        let binary = std::path::Path::new("/Applications/FnSpeak.app/Contents/Resources/llama-server");
        let models = std::path::Path::new("/Users/me/Library/Application Support/FnSpeak/Models");
        // 102 still has a parent, 103 is someone else's, 105 isn't a llama-server.
        assert_eq!(orphans(ps, binary, Some(models)), vec![101, 104]);
    }
}
