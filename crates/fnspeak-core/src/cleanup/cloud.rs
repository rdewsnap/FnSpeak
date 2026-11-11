//! Hosted cleanup. Only text is sent: the filtered transcript, relevant
//! vocabulary and a little on-screen context. Audio never leaves the machine.

use super::{build_user_message, tidy_output, Cleaner, CleanupError, CleanupRequest, Llm, SYSTEM_PROMPT};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Cleanup sits between "stop talking" and "text appears"; past this, the
/// rule-based output is inserted instead.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(4);
/// Cleaned dictation is short; this is a ceiling, not a target.
const MAX_OUTPUT_TOKENS: u32 = 2048;
/// Summaries run in the background and can take a while on a slow model.
const COMPLETION_TIMEOUT: Duration = Duration::from_secs(300);

fn client() -> Result<reqwest::blocking::Client, CleanupError> {
    reqwest::blocking::Client::builder().build().map_err(|e| CleanupError::Load(e.to_string()))
}

fn send(req: reqwest::blocking::RequestBuilder) -> Result<Value, CleanupError> {
    let resp = req.send().map_err(|e| CleanupError::Request(e.to_string()))?;
    let status = resp.status();
    let body: Value = resp.json().map_err(|e| CleanupError::Request(e.to_string()))?;
    if !status.is_success() {
        let message = body["error"]["message"].as_str().unwrap_or("no error message");
        return Err(CleanupError::Request(format!("HTTP {status}: {message}")));
    }
    Ok(body)
}

/// Claude via the Messages API. Used with the user's own key, and as the
/// heavy model behind FnSpeak Cloud.
#[derive(Clone)]
pub struct AnthropicCleaner {
    api_key: String,
    model: String,
    base_url: String,
    http: reqwest::blocking::Client,
}

impl AnthropicCleaner {
    pub const DEFAULT_MODEL: &'static str = "claude-haiku-5-5";

    pub fn new(api_key: impl Into<String>, model: Option<String>) -> Result<Self, CleanupError> {
        Ok(AnthropicCleaner {
            api_key: api_key.into(),
            model: model.unwrap_or_else(|| Self::DEFAULT_MODEL.to_string()),
            base_url: "https://api.anthropic.com".into(),
            http: client()?,
        })
    }

    pub fn with_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = base_url.into();
        self
    }

    fn messages(&self, mut body: Value, timeout: Duration) -> Result<String, CleanupError> {
        body["model"] = json!(self.model);
        let resp = send(
            self.http
                .post(format!("{}/v1/messages", self.base_url))
                .timeout(timeout)
                .header("x-api-key", &self.api_key)
                .header("anthropic-version", "2026-10-21")
                .json(&body),
        )?;

        match resp["stop_reason"].as_str() {
            Some("refusal") => return Err(CleanupError::Refused),
            Some("max_tokens") => return Err(CleanupError::Rejected("output cut off".into())),
            _ => {}
        }
        let text: String = resp["content"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|b| b["type"] == "text")
            .filter_map(|b| b["text"].as_str())
            .collect();
        Ok(tidy_output(&text))
    }
}

impl Cleaner for AnthropicCleaner {
    fn name(&self) -> String {
        format!("anthropic:{}", self.model)
    }

    fn clean(&mut self, req: &CleanupRequest<'_>) -> Result<String, CleanupError> {
        let body = json!({
            "max_tokens": MAX_OUTPUT_TOKENS,
            "system": SYSTEM_PROMPT,
            // A rewrite this small doesn't need thinking, and latency matters.
            "thinking": {"type": "disabled"},
            "output_config": {"effort": "low"},
            "messages": [{"role": "user", "content": build_user_message(req)}],
        });
        self.messages(body, DEFAULT_TIMEOUT)
    }

    fn llm(&self) -> Option<Box<dyn Llm>> {
        Some(Box::new(self.clone()))
    }
}

impl Llm for AnthropicCleaner {
    fn name(&self) -> String {
        Cleaner::name(self)
    }

    fn context_tokens(&self) -> usize {
        200_000
    }

    fn complete(&self, system: &str, user: &str, max_tokens: u32) -> Result<String, CleanupError> {
        let body = json!({
            "max_tokens": max_tokens,
            "system": system,
            "thinking": {"type": "disabled"},
            "messages": [{"role": "user", "content": user}],
        });
        self.messages(body, COMPLETION_TIMEOUT)
    }
}

/// Any OpenAI-style chat completions endpoint: Groq, OpenRouter, OpenAI,
/// The request fields OpenAI-compatible servers disagree on. OpenAI's
/// current models reject `max_tokens` and a fixed temperature, and reason
/// before answering unless told not to; most other servers only know the
/// older fields. Start from a guess per host and adjust when a server says
/// which field it won't take.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Dialect {
    completion_tokens: bool,
    temperature: bool,
    no_reasoning: bool,
}

impl Dialect {
    fn for_url(base_url: &str) -> Self {
        let openai = base_url == OpenAiCompatCleaner::OPENAI;
        Dialect { completion_tokens: openai, temperature: true, no_reasoning: openai }
    }

    /// Drop or swap the field a 400 complains about. False if the error is
    /// about something else, so the caller stops retrying.
    fn adapt(&mut self, error: &str) -> bool {
        if self.no_reasoning && error.contains("reasoning_effort") {
            self.no_reasoning = false;
        } else if self.temperature && error.contains("temperature") {
            self.temperature = false;
        } else if !self.completion_tokens && error.contains("max_completion_tokens") {
            self.completion_tokens = true;
        } else {
            return false;
        }
        true
    }
}

/// Ollama or LM Studio on another machine, and FnSpeak Cloud.
#[derive(Clone)]
pub struct OpenAiCompatCleaner {
    base_url: String,
    api_key: Option<String>,
    model: String,
    timeout: Duration,
    context_tokens: usize,
    /// Ask the server to keep the shared prompt prefix in its KV cache.
    /// llama-server only; hosted APIs would reject the extra field.
    cache_prompt: bool,
    /// Shared between clones, so what one request learns the next one uses.
    dialect: Arc<Mutex<Dialect>>,
    http: reqwest::blocking::Client,
}

impl OpenAiCompatCleaner {
    pub const GROQ: &'static str = "https://api.groq.com/openai/v1";
    pub const OPENROUTER: &'static str = "https://openrouter.ai/api/v1";
    pub const OPENAI: &'static str = "https://api.openai.com/v1";
    pub const OLLAMA: &'static str = "http://localhost:11434/v1";

    // Groq model ids at the time of writing; check their model list if these 404.
    pub const GROQ_LIGHT: &'static str = "llama-3.1-8b-instant";
    pub const GROQ_MID: &'static str = "meta-llama/llama-4-scout-17b-16e-instruct";
    pub const GROQ_HEAVY: &'static str = "llama-3.3-70b-versatile";

    pub fn new(base_url: impl Into<String>, api_key: Option<String>, model: impl Into<String>) -> Result<Self, CleanupError> {
        let base_url = base_url.into().trim_end_matches('/').to_string();
        // The big hosted providers serve long-context models. Anything else
        // (Ollama, LM Studio) may be running a small window.
        let context_tokens = if [Self::GROQ, Self::OPENROUTER, Self::OPENAI].contains(&base_url.as_str()) { 128_000 } else { 8_192 };
        let dialect = Arc::new(Mutex::new(Dialect::for_url(&base_url)));
        Ok(OpenAiCompatCleaner {
            base_url,
            api_key,
            model: model.into(),
            timeout: DEFAULT_TIMEOUT,
            context_tokens,
            cache_prompt: false,
            dialect,
            http: client()?,
        })
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Result<Self, CleanupError> {
        self.timeout = timeout;
        Ok(self)
    }

    pub fn with_context_tokens(mut self, tokens: usize) -> Self {
        self.context_tokens = tokens;
        self
    }

    /// Send `cache_prompt` with every request, so the system prompt is only
    /// processed once per server.
    pub fn with_prompt_cache(mut self) -> Self {
        self.cache_prompt = true;
        self
    }

    /// A one-token completion with the cleanup system prompt, to keep the
    /// server's GPU clocks up and its prompt cache populated. Errors are
    /// ignored: a 1-token reply always reports `length`, and a dead server
    /// will show up on the next real dictation anyway.
    pub fn warm(&self, timeout: Duration) {
        let _ = self.chat(SYSTEM_PROMPT, "hi", 1, timeout);
    }

    fn chat(&self, system: &str, user: &str, max_tokens: u32, timeout: Duration) -> Result<String, CleanupError> {
        let mut dialect = *self.dialect.lock().unwrap_or_else(|e| e.into_inner());
        let resp = loop {
            let mut body = json!({
                "model": self.model,
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
            });
            body[if dialect.completion_tokens { "max_completion_tokens" } else { "max_tokens" }] = json!(max_tokens);
            if dialect.temperature {
                body["temperature"] = json!(0);
            }
            if dialect.no_reasoning {
                body["reasoning_effort"] = json!("none");
            }
            if self.cache_prompt {
                body["cache_prompt"] = json!(true);
            }
            let mut http = self.http.post(format!("{}/chat/completions", self.base_url)).timeout(timeout).json(&body);
            if let Some(key) = &self.api_key {
                http = http.bearer_auth(key);
            }
            match send(http) {
                // Each retry gives up one field, so this ends in three at most.
                Err(CleanupError::Request(e)) if e.starts_with("HTTP 400") && dialect.adapt(&e) => {
                    log::info!("{}: adjusting the request after: {e}", self.model);
                    *self.dialect.lock().unwrap_or_else(|e| e.into_inner()) = dialect;
                }
                other => break other?,
            }
        };

        // llama-server reports how much of the prompt it had to process. A
        // prompt_n near the full system prompt means the cache missed.
        let timings = &resp["timings"];
        if timings.is_object() {
            log::debug!(
                "{}: prompt {} tokens in {:.0} ms ({} cached), {} generated in {:.0} ms",
                self.model,
                timings["prompt_n"],
                timings["prompt_ms"].as_f64().unwrap_or(0.0),
                timings["cache_n"],
                timings["predicted_n"],
                timings["predicted_ms"].as_f64().unwrap_or(0.0),
            );
        }

        let choice = &resp["choices"][0];
        if choice["finish_reason"] == "length" {
            return Err(CleanupError::Rejected("output cut off".into()));
        }
        let text = choice["message"]["content"].as_str().unwrap_or_default();
        Ok(tidy_output(text))
    }
}

impl Cleaner for OpenAiCompatCleaner {
    fn name(&self) -> String {
        format!("openai-compat:{}", self.model)
    }

    fn clean(&mut self, req: &CleanupRequest<'_>) -> Result<String, CleanupError> {
        self.chat(SYSTEM_PROMPT, &build_user_message(req), MAX_OUTPUT_TOKENS, self.timeout)
    }

    fn llm(&self) -> Option<Box<dyn Llm>> {
        Some(Box::new(self.clone()))
    }
}

impl Llm for OpenAiCompatCleaner {
    fn name(&self) -> String {
        Cleaner::name(self)
    }

    fn context_tokens(&self) -> usize {
        self.context_tokens
    }

    fn complete(&self, system: &str, user: &str, max_tokens: u32) -> Result<String, CleanupError> {
        self.chat(system, user, max_tokens, COMPLETION_TIMEOUT)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dialect_follows_what_openai_rejects() {
        // The messages are OpenAI's, word for word.
        let mut d = Dialect { completion_tokens: false, temperature: true, no_reasoning: false };
        assert!(d.adapt("HTTP 400 Bad Request: Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."));
        assert!(d.completion_tokens);

        let mut d = Dialect::for_url(OpenAiCompatCleaner::OPENAI);
        assert_eq!(d, Dialect { completion_tokens: true, temperature: true, no_reasoning: true });
        assert!(d.adapt("HTTP 400 Bad Request: Unsupported value: 'temperature' does not support 0 with this model. Only the default (1) value is supported."));
        assert!(d.adapt("HTTP 400 Bad Request: Unrecognized request argument supplied: reasoning_effort"));
        assert_eq!(d, Dialect { completion_tokens: true, temperature: false, no_reasoning: false });
        // Nothing left to give up, and unrelated errors don't loop.
        assert!(!d.adapt("HTTP 400 Bad Request: Unsupported value: 'temperature' does not support 0"));
        assert!(!d.adapt("HTTP 400 Bad Request: model not found"));
    }

    #[test]
    fn other_servers_keep_the_older_fields() {
        let d = Dialect::for_url(OpenAiCompatCleaner::GROQ);
        assert_eq!(d, Dialect { completion_tokens: false, temperature: true, no_reasoning: false });
    }
}
