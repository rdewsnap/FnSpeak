//! Hosted cleanup. Only text is sent: the filtered transcript, relevant
//! vocabulary and a little on-screen context. Audio never leaves the machine.

use super::{build_user_message, tidy_output, Cleaner, CleanupError, CleanupRequest, SYSTEM_PROMPT};
use serde_json::{json, Value};
use std::time::Duration;

/// Cleanup sits between "stop talking" and "text appears"; past this, the
/// rule-based output is inserted instead.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(4);
/// Cleaned dictation is short; this is a ceiling, not a target.
const MAX_OUTPUT_TOKENS: u32 = 2048;

fn client(timeout: Duration) -> Result<reqwest::blocking::Client, CleanupError> {
    reqwest::blocking::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|e| CleanupError::Load(e.to_string()))
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
            http: client(DEFAULT_TIMEOUT)?,
        })
    }

    pub fn with_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = base_url.into();
        self
    }
}

impl Cleaner for AnthropicCleaner {
    fn name(&self) -> String {
        format!("anthropic:{}", self.model)
    }

    fn clean(&mut self, req: &CleanupRequest<'_>) -> Result<String, CleanupError> {
        let body = json!({
            "model": self.model,
            "max_tokens": MAX_OUTPUT_TOKENS,
            "system": SYSTEM_PROMPT,
            // A rewrite this small doesn't need thinking, and latency matters.
            "thinking": {"type": "disabled"},
            "output_config": {"effort": "low"},
            "messages": [{"role": "user", "content": build_user_message(req)}],
        });
        let resp = send(
            self.http
                .post(format!("{}/v1/messages", self.base_url))
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

/// Any OpenAI-style chat completions endpoint: Groq, OpenRouter, OpenAI,
/// Ollama or LM Studio on another machine, and Flowstate Cloud.
pub struct OpenAiCompatCleaner {
    base_url: String,
    api_key: Option<String>,
    model: String,
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
        Ok(OpenAiCompatCleaner {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            api_key,
            model: model.into(),
            http: client(DEFAULT_TIMEOUT)?,
        })
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Result<Self, CleanupError> {
        self.http = client(timeout)?;
        Ok(self)
    }
}

impl Cleaner for OpenAiCompatCleaner {
    fn name(&self) -> String {
        format!("openai-compat:{}", self.model)
    }

    fn clean(&mut self, req: &CleanupRequest<'_>) -> Result<String, CleanupError> {
        let body = json!({
            "model": self.model,
            "max_tokens": MAX_OUTPUT_TOKENS,
            "temperature": 0,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": build_user_message(req)},
            ],
        });
        let mut http = self.http.post(format!("{}/chat/completions", self.base_url)).json(&body);
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
