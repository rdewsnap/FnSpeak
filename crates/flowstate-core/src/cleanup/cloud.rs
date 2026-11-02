//! Hosted cleanup. Only text is sent: the filtered transcript, relevant
//! vocabulary and a little on-screen context. Audio never leaves the machine.

use super::{build_user_message, tidy_output, Cleaner, CleanupError, CleanupRequest, Llm, SYSTEM_PROMPT};
use serde_json::{json, Value};
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
/// heavy model behind Flowstate Cloud.
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
/// Ollama or LM Studio on another machine, and Flowstate Cloud.
#[derive(Clone)]
pub struct OpenAiCompatCleaner {
    base_url: String,
    api_key: Option<String>,
    model: String,
    timeout: Duration,
    context_tokens: usize,
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
        Ok(OpenAiCompatCleaner { base_url, api_key, model: model.into(), timeout: DEFAULT_TIMEOUT, context_tokens, http: client()? })
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Result<Self, CleanupError> {
        self.timeout = timeout;
        Ok(self)
    }

    pub fn with_context_tokens(mut self, tokens: usize) -> Self {
        self.context_tokens = tokens;
        self
    }

    fn chat(&self, system: &str, user: &str, max_tokens: u32, timeout: Duration) -> Result<String, CleanupError> {
        let body = json!({
            "model": self.model,
            "max_tokens": max_tokens,
            "temperature": 0,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        });
        let mut http = self.http.post(format!("{}/chat/completions", self.base_url)).timeout(timeout).json(&body);
        if let Some(key) = &self.api_key {
            http = http.bearer_auth(key);
        }
        let resp = send(http)?;

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
