//! Hosted cleanup and meeting summaries, forwarded to a configured upstream
//! model.
//!
//! Request and response text is never logged or stored. Cleanup uses the same prompt as the app's local and bring-your-own-key
//! modes, and the app still runs its guardrail on what comes back.

use axum::extract::State;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::fmt::Write;
use std::time::Duration;

use crate::auth::AuthUser;
use crate::config::{LlmConfig, LlmProvider};
use crate::error::{ApiError, ApiResult};
use crate::AppState;

pub const CLEANUP_PROMPT: &str = include_str!("../../../prompts/cleanup_system.md");
pub const SUMMARY_PROMPT: &str = include_str!("../prompts/summarize_system.md");

const ANTHROPIC_VERSION: &str = "2026-10-21";
const CLEANUP_TIMEOUT: Duration = Duration::from_secs(15);
const SUMMARY_TIMEOUT: Duration = Duration::from_secs(180);
const CLEANUP_MAX_TOKENS: u32 = 2048;
const SUMMARY_MAX_TOKENS: u32 = 8192;
const MAX_DICTATION_CHARS: usize = 20_000;
const MAX_TRANSCRIPT_BYTES: usize = 2 * 1024 * 1024;
const MAX_VOCAB: usize = 40;
const MAX_CONTEXT_CHARS: usize = 500;

pub struct Completion {
    pub text: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
}

enum Effort {
    Low,
    Default,
}

struct Call<'a> {
    model: &'a str,
    system: &'a str,
    user: &'a str,
    max_tokens: u32,
    effort: Effort,
    timeout: Duration,
}

async fn complete(http: &reqwest::Client, llm: &LlmConfig, call: Call<'_>) -> ApiResult<Completion> {
    let Call { model, system, user, max_tokens, effort, timeout } = call;
    let upstream = |e: reqwest::Error| {
        // reqwest errors can include the URL but never the body.
        tracing::warn!(error = %e, "upstream model request failed");
        ApiError::Upstream("the hosted model couldn't be reached; try again".into())
    };
    match llm.provider {
        LlmProvider::Anthropic => {
            let mut body = json!({
                "model": model,
                "max_tokens": max_tokens,
                "system": system,
                "messages": [{ "role": "user", "content": user }],
            });
            if let Effort::Low = effort {
                // Cleanup is a small rewrite where latency matters more than depth.
                body["thinking"] = json!({ "type": "disabled" });
                body["output_config"] = json!({ "effort": "low" });
            }
            let resp = http
                .post(format!("{}/v1/messages", llm.base_url))
                .timeout(timeout)
                .header("x-api-key", &llm.api_key)
                .header("anthropic-version", ANTHROPIC_VERSION)
                .json(&body)
                .send()
                .await
                .map_err(upstream)?;
            let v = read(resp).await?;
            let usage = (v["usage"]["input_tokens"].as_i64().unwrap_or(0), v["usage"]["output_tokens"].as_i64().unwrap_or(0));
            if v["stop_reason"] == "refusal" {
                return Err(ApiError::Upstream("the hosted model declined this request".into()));
            }
            let text: String = v["content"]
                .as_array()
                .map(|blocks| blocks.iter().filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect())
                .unwrap_or_default();
            Ok(Completion { text, input_tokens: usage.0, output_tokens: usage.1 })
        }
        LlmProvider::OpenAi => {
            let body = json!({
                "model": model,
                "max_tokens": max_tokens,
                "messages": [
                    { "role": "system", "content": system },
                    { "role": "user", "content": user },
                ],
            });
            let resp = http
                .post(format!("{}/chat/completions", llm.base_url))
                .timeout(timeout)
                .bearer_auth(&llm.api_key)
                .json(&body)
                .send()
                .await
                .map_err(upstream)?;
            let v = read(resp).await?;
            let choice = &v["choices"][0];
            if choice["finish_reason"] == "content_filter" {
                return Err(ApiError::Upstream("the hosted model declined this request".into()));
            }
            Ok(Completion {
                text: choice["message"]["content"].as_str().unwrap_or_default().to_string(),
                input_tokens: v["usage"]["prompt_tokens"].as_i64().unwrap_or(0),
                output_tokens: v["usage"]["completion_tokens"].as_i64().unwrap_or(0),
            })
        }
    }
}

async fn read(resp: reqwest::Response) -> ApiResult<Value> {
    let status = resp.status();
    let v: Value = resp.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        // Upstream error messages describe the request, not its content.
        let message = v["error"]["message"].as_str().unwrap_or("no message");
        tracing::warn!(%status, message, "upstream model returned an error");
        return Err(if status.as_u16() == 429 || status.is_server_error() {
            ApiError::Unavailable("the hosted model is busy; try again shortly".into())
        } else {
            ApiError::Upstream(format!("the hosted model rejected the request ({status})"))
        });
    }
    Ok(v)
}

/// Strip the `<think>` block some open models emit, and stray whitespace.
fn tidy(raw: &str) -> String {
    let raw = match (raw.find("<think>"), raw.find("</think>")) {
        (Some(start), Some(end)) if end > start => format!("{}{}", &raw[..start], &raw[end + "</think>".len()..]),
        _ => raw.to_string(),
    };
    raw.trim().to_string()
}

fn llm_config(state: &AppState) -> ApiResult<&LlmConfig> {
    state.config.llm.as_ref().ok_or_else(|| ApiError::Unavailable("hosted cleanup isn't set up on this server".into()))
}

#[derive(Deserialize)]
pub struct LikelyFix {
    heard: String,
    term: String,
}

/// What the app already knows about a dictation, as in its local cleanup.
#[derive(Deserialize)]
pub struct CleanupRequest {
    /// Transcript after the app's rule-based filter.
    transcript: String,
    #[serde(default)]
    app_name: String,
    #[serde(default)]
    window_title: String,
    /// Text before the cursor; only the last few hundred characters are used.
    #[serde(default)]
    text_before: String,
    /// Writing-style instructions for the target app.
    #[serde(default)]
    style: String,
    #[serde(default)]
    vocabulary: Vec<String>,
    #[serde(default)]
    likely_fixes: Vec<LikelyFix>,
}

/// The user message for cleanup, laid out the way the app's prompt expects.
fn cleanup_message(req: &CleanupRequest) -> String {
    let mut msg = String::new();
    let recent: String = {
        let t = req.text_before.trim();
        let skip = t.chars().count().saturating_sub(MAX_CONTEXT_CHARS);
        t.chars().skip(skip).collect()
    };
    if !req.app_name.is_empty() || !req.window_title.is_empty() || !recent.is_empty() {
        msg.push_str("<context>\n");
        if !req.app_name.is_empty() {
            let _ = writeln!(msg, "App: {}", req.app_name);
        }
        if !req.window_title.is_empty() {
            let _ = writeln!(msg, "Window: {}", req.window_title);
        }
        if !recent.is_empty() {
            let _ = writeln!(msg, "Text before cursor: {recent}");
        }
        msg.push_str("</context>\n");
    }
    let style = if req.style.trim().is_empty() { "Clear written prose." } else { req.style.trim() };
    let _ = writeln!(msg, "<style>{style}</style>");
    let vocab: Vec<&str> = req.vocabulary.iter().map(|t| t.trim()).filter(|t| !t.is_empty()).take(MAX_VOCAB).collect();
    if !vocab.is_empty() {
        let _ = writeln!(msg, "<vocabulary>{}</vocabulary>", vocab.join(", "));
    }
    let fixes: Vec<String> = req.likely_fixes.iter().map(|f| format!("\"{}\" → {}", f.heard, f.term)).collect();
    if !fixes.is_empty() {
        let _ = writeln!(msg, "<likely_fixes>\n{}\n</likely_fixes>", fixes.join("\n"));
    }
    let _ = write!(msg, "<transcript>{}</transcript>", req.transcript);
    msg
}

/// `POST /v1/cleanup`
pub async fn cleanup(
    State(state): State<AppState>,
    _user: AuthUser,
    Json(req): Json<CleanupRequest>,
) -> ApiResult<Json<Value>> {
    let llm = llm_config(&state)?;
    if req.transcript.trim().is_empty() {
        return Ok(Json(json!({ "text": "", "model": null, "usage": { "input_tokens": 0, "output_tokens": 0 } })));
    }
    if req.transcript.chars().count() > MAX_DICTATION_CHARS {
        return Err(ApiError::bad("transcript is too long for cleanup"));
    }
    let out = run_cleanup(&state, llm, &cleanup_message(&req)).await?;
    Ok(Json(json!({
        "text": tidy(&out.text),
        "model": llm.model,
        "usage": { "input_tokens": out.input_tokens, "output_tokens": out.output_tokens },
    })))
}

async fn run_cleanup(state: &AppState, llm: &LlmConfig, user_message: &str) -> ApiResult<Completion> {
    let call = Call {
        model: &llm.model,
        system: CLEANUP_PROMPT,
        user: user_message,
        max_tokens: CLEANUP_MAX_TOKENS,
        effort: Effort::Low,
        timeout: CLEANUP_TIMEOUT,
    };
    complete(&state.http, llm, call).await
}

#[derive(Deserialize)]
pub struct ChatMessage {
    role: String,
    #[serde(default)]
    content: Value,
}

#[derive(Deserialize)]
pub struct ChatRequest {
    messages: Vec<ChatMessage>,
}

/// `POST /v1/chat/completions`: the request shape the app's existing
/// OpenAI-compatible cloud mode sends, so it can use this server as is.
/// Only cleanup is served: the client's system prompt and model are
/// ignored and replaced with the server's, so this isn't a general proxy.
pub async fn chat_completions(
    State(state): State<AppState>,
    _user: AuthUser,
    Json(req): Json<ChatRequest>,
) -> ApiResult<Json<Value>> {
    let llm = llm_config(&state)?;
    let user_message = req
        .messages
        .iter()
        .rev()
        .find(|m| m.role == "user")
        .and_then(|m| m.content.as_str())
        .ok_or_else(|| ApiError::bad("expected a user message with text content"))?;
    if user_message.chars().count() > MAX_DICTATION_CHARS + 4_000 {
        return Err(ApiError::bad("message is too long for cleanup"));
    }
    let out = run_cleanup(&state, llm, user_message).await?;
    Ok(Json(json!({
        "id": format!("fs-{}", crate::db::new_id()),
        "object": "chat.completion",
        "created": crate::db::now_ms() / 1000,
        "model": llm.model,
        "choices": [{
            "index": 0,
            "message": { "role": "assistant", "content": tidy(&out.text) },
            "finish_reason": "stop",
        }],
        "usage": {
            "prompt_tokens": out.input_tokens,
            "completion_tokens": out.output_tokens,
            "total_tokens": out.input_tokens + out.output_tokens,
        },
    })))
}

#[derive(Deserialize)]
pub struct SummarizeRequest {
    /// Markdown transcript, ideally with speaker labels.
    transcript: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    participants: Vec<String>,
    #[serde(default)]
    vocabulary: Vec<String>,
}

fn summary_message(req: &SummarizeRequest) -> String {
    let mut msg = String::new();
    if !req.title.trim().is_empty() {
        let _ = writeln!(msg, "<title>{}</title>", req.title.trim());
    }
    if !req.participants.is_empty() {
        let _ = writeln!(msg, "<participants>{}</participants>", req.participants.join(", "));
    }
    let vocab: Vec<&str> = req.vocabulary.iter().map(|t| t.trim()).filter(|t| !t.is_empty()).take(MAX_VOCAB).collect();
    if !vocab.is_empty() {
        let _ = writeln!(msg, "<vocabulary>{}</vocabulary>", vocab.join(", "));
    }
    let _ = write!(msg, "<transcript>\n{}\n</transcript>", req.transcript);
    msg
}

/// Pull `{"summary_md", "action_items"}` out of the model's reply. A reply
/// that isn't the expected JSON becomes the summary as-is.
fn parse_summary(raw: &str) -> (String, Value) {
    let text = tidy(raw);
    let body = text
        .strip_prefix("```json")
        .or_else(|| text.strip_prefix("```"))
        .and_then(|t| t.strip_suffix("```"))
        .unwrap_or(&text)
        .trim();
    let parsed = serde_json::from_str::<Value>(body).ok().or_else(|| {
        let (start, end) = (body.find('{')?, body.rfind('}')?);
        serde_json::from_str(&body[start..=end]).ok()
    });
    match parsed {
        Some(v) if v["summary_md"].is_string() => {
            let items = if v["action_items"].is_array() { v["action_items"].clone() } else { json!([]) };
            (v["summary_md"].as_str().unwrap_or_default().to_string(), items)
        }
        _ => (text, json!([])),
    }
}

/// `POST /v1/summarize`
pub async fn summarize(
    State(state): State<AppState>,
    _user: AuthUser,
    Json(req): Json<SummarizeRequest>,
) -> ApiResult<Json<Value>> {
    let llm = llm_config(&state)?;
    if req.transcript.trim().is_empty() {
        return Err(ApiError::bad("transcript is empty"));
    }
    if req.transcript.len() > MAX_TRANSCRIPT_BYTES {
        return Err(ApiError::bad("transcript is too long to summarize"));
    }
    let user_message = summary_message(&req);
    let call = Call {
        model: &llm.summary_model,
        system: SUMMARY_PROMPT,
        user: &user_message,
        max_tokens: SUMMARY_MAX_TOKENS,
        effort: Effort::Default,
        timeout: SUMMARY_TIMEOUT,
    };
    let out = complete(&state.http, llm, call).await?;
    let (summary_md, action_items) = parse_summary(&out.text);
    Ok(Json(json!({
        "summary_md": summary_md,
        "action_items": action_items,
        "model": llm.summary_model,
        "usage": { "input_tokens": out.input_tokens, "output_tokens": out.output_tokens },
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompts_are_embedded() {
        assert!(CLEANUP_PROMPT.contains("Resolve self-corrections"));
        assert!(SUMMARY_PROMPT.contains("action_items"));
    }

    #[test]
    fn cleanup_message_matches_the_app_layout() {
        let req = CleanupRequest {
            transcript: "yep kin ju is live".into(),
            app_name: "Slack".into(),
            window_title: "#eng".into(),
            text_before: "did the deploy go out?".into(),
            style: "Casual chat.".into(),
            vocabulary: vec!["Kinju".into()],
            likely_fixes: vec![LikelyFix { heard: "kin ju".into(), term: "Kinju".into() }],
        };
        let msg = cleanup_message(&req);
        assert!(msg.starts_with("<context>\nApp: Slack\nWindow: #eng\nText before cursor: did the deploy go out?\n</context>"));
        assert!(msg.contains("<style>Casual chat.</style>"));
        assert!(msg.contains("<vocabulary>Kinju</vocabulary>"));
        assert!(msg.contains("\"kin ju\" → Kinju"));
        assert!(msg.ends_with("<transcript>yep kin ju is live</transcript>"));
    }

    #[test]
    fn parses_summary_json_with_or_without_a_fence() {
        let (s, items) = parse_summary("```json\n{\"summary_md\": \"Shipped.\", \"action_items\": [{\"text\": \"Tag release\"}]}\n```");
        assert_eq!(s, "Shipped.");
        assert_eq!(items[0]["text"], "Tag release");
        let (s, items) = parse_summary("Just prose.");
        assert_eq!(s, "Just prose.");
        assert_eq!(items, json!([]));
    }
}
