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
/// Shared with the app's local meeting summaries.
pub const SUMMARY_PROMPT: &str = include_str!("../../../prompts/meeting_summary.md");

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
            let mut body = json!({
                "model": model,
                "messages": [
                    { "role": "system", "content": system },
                    { "role": "user", "content": user },
                ],
            });
            body[tokens_field(&llm.base_url)] = json!(max_tokens);
            if let (Effort::Low, Some(level)) = (&effort, &llm.reasoning_effort) {
                body["reasoning_effort"] = json!(level);
            }
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

/// OpenAI's current models reject `max_tokens`; other OpenAI-compatible
/// servers may only know that name.
fn tokens_field(base_url: &str) -> &'static str {
    if crate::config::host_of(base_url) == "api.openai.com" {
        "max_completion_tokens"
    } else {
        "max_tokens"
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

/// Either the exact message the app builds for one summary step (which
/// lets it chunk long meetings itself), or the parts to build it from.
#[derive(Deserialize)]
pub struct SummarizeRequest {
    /// A complete prompt input: `<meeting>…</meeting>` followed by a
    /// `<transcript>`, `<transcript part="…">` or `<partial_summaries>`.
    #[serde(default)]
    input: Option<String>,
    /// Transcript lines like `[00:12:34] Me: text`.
    #[serde(default)]
    transcript: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    participants: Vec<String>,
    /// Whether the user spoke; decides "we" or third person. Defaults to
    /// whether any transcript line is from "Me".
    #[serde(default)]
    user_took_part: Option<bool>,
    #[serde(default)]
    vocabulary: Vec<String>,
}

/// The same layout as the app's local summaries.
fn summary_message(req: &SummarizeRequest) -> String {
    if let Some(input) = req.input.as_deref().filter(|i| !i.trim().is_empty()) {
        return input.to_string();
    }
    let mut msg = String::from("<meeting>\n");
    if !req.title.trim().is_empty() {
        let _ = writeln!(msg, "Title: {}", req.title.trim());
    }
    if !req.participants.is_empty() {
        let _ = writeln!(msg, "Participants: {}", req.participants.join(", "));
    }
    let took_part = req.user_took_part.unwrap_or_else(|| {
        req.transcript.lines().any(|l| {
            let l = l.trim_start();
            let l = l.strip_prefix('[').and_then(|r| r.split_once(']')).map_or(l, |(_, rest)| rest.trim_start());
            l.starts_with("Me:")
        })
    });
    if took_part {
        msg.push_str("Perspective: the user took part; write as \"we\".\n");
    } else {
        msg.push_str("Perspective: the user only listened; write in the third person.\n");
    }
    msg.push_str("</meeting>\n");
    let vocab: Vec<&str> = req.vocabulary.iter().map(|t| t.trim()).filter(|t| !t.is_empty()).take(MAX_VOCAB).collect();
    if !vocab.is_empty() {
        let _ = writeln!(msg, "<vocabulary>{}</vocabulary>", vocab.join(", "));
    }
    let _ = write!(msg, "<transcript>\n{}\n</transcript>", req.transcript.trim_end());
    msg
}

/// Action items from the summary's "Action items" section, written as
/// `- [ ] Owner: task (due)`, in the shape the app stores them.
fn parse_action_items(summary_md: &str) -> Value {
    let mut items = Vec::new();
    let mut in_section = false;
    for line in summary_md.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('#') {
            in_section = trimmed.trim_start_matches('#').trim().to_lowercase().starts_with("action item");
            continue;
        }
        let Some(rest) = trimmed.strip_prefix(['-', '*', '+']).filter(|_| in_section) else { continue };
        let rest = rest.trim_start();
        let (done, rest) = match rest.get(..3) {
            Some("[ ]") => (false, &rest[3..]),
            Some("[x]" | "[X]") => (true, &rest[3..]),
            _ => (false, rest),
        };
        let mut rest = rest.trim().trim_end_matches('.').trim().to_string();
        if rest.is_empty() || rest.eq_ignore_ascii_case("none") {
            continue;
        }
        let mut due = None;
        if rest.ends_with(')') {
            if let Some(open) = rest.rfind('(') {
                let inner = rest[open + 1..rest.len() - 1].trim().to_string();
                if !inner.is_empty() && !inner.contains(['(', ')']) {
                    due = Some(inner);
                    rest.truncate(open);
                }
            }
        }
        let (owner, task) = match rest.split_once(':') {
            // "Priya: …" or "Me and Sam: …", but not a task with a colon in it.
            Some((owner, task)) if looks_like_names(owner) && !task.trim().is_empty() => {
                (Some(owner.trim().to_string()), task.trim().to_string())
            }
            _ => (None, rest.trim().to_string()),
        };
        items.push(json!({ "owner": owner, "task": task, "due": due, "done": done }));
    }
    Value::Array(items)
}

fn looks_like_names(text: &str) -> bool {
    let words: Vec<&str> = text.split_whitespace().collect();
    (1..=4).contains(&words.len())
        && words.iter().all(|w| matches!(*w, "and" | "&" | "or") || w.chars().next().is_some_and(char::is_uppercase))
}

/// `POST /v1/summarize`
pub async fn summarize(
    State(state): State<AppState>,
    _user: AuthUser,
    Json(req): Json<SummarizeRequest>,
) -> ApiResult<Json<Value>> {
    let llm = llm_config(&state)?;
    let user_message = summary_message(&req);
    if req.transcript.trim().is_empty() && req.input.as_deref().is_none_or(|i| i.trim().is_empty()) {
        return Err(ApiError::bad("send a transcript or an input"));
    }
    if user_message.len() > MAX_TRANSCRIPT_BYTES {
        return Err(ApiError::bad("transcript is too long to summarize"));
    }
    let call = Call {
        model: &llm.summary_model,
        system: SUMMARY_PROMPT,
        user: &user_message,
        max_tokens: SUMMARY_MAX_TOKENS,
        effort: Effort::Default,
        timeout: SUMMARY_TIMEOUT,
    };
    let out = complete(&state.http, llm, call).await?;
    let summary_md = tidy(&out.text);
    Ok(Json(json!({
        "action_items": parse_action_items(&summary_md),
        "summary_md": summary_md,
        "model": llm.summary_model,
        "usage": { "input_tokens": out.input_tokens, "output_tokens": out.output_tokens },
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn openai_itself_gets_the_newer_token_field() {
        assert_eq!(tokens_field("https://api.openai.com/v1"), "max_completion_tokens");
        assert_eq!(tokens_field("https://api.groq.com/openai/v1"), "max_tokens");
        assert_eq!(tokens_field("http://localhost:11434/v1"), "max_tokens");
    }

    #[test]
    fn prompts_are_embedded() {
        assert!(CLEANUP_PROMPT.contains("Resolve self-corrections"));
        assert!(SUMMARY_PROMPT.contains("## Action items"));
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
    fn builds_the_meeting_header_like_the_app() {
        let req = SummarizeRequest {
            input: None,
            transcript: "[00:00:04] Me: ship Friday?\n[00:00:09] Others: yes".into(),
            title: "Launch sync".into(),
            participants: vec!["Priya Raman".into(), "Sam".into()],
            user_took_part: None,
            vocabulary: vec!["Kinju".into()],
        };
        let msg = summary_message(&req);
        assert!(msg.starts_with("<meeting>\nTitle: Launch sync\nParticipants: Priya Raman, Sam\nPerspective: the user took part"));
        assert!(msg.contains("</meeting>\n<vocabulary>Kinju</vocabulary>\n<transcript>\n[00:00:04]"));
    }

    #[test]
    fn parses_action_items() {
        let md = "## Summary\n- Shipped.\n\n## Action items\n- [ ] Me: Write the release notes (Thursday)\n\
                  - [x] Tag the build\n- [ ] Find out: does legal sign off?\n\n## Open questions\n- [ ] Not an item";
        let items = parse_action_items(md);
        assert_eq!(items.as_array().unwrap().len(), 3);
        assert_eq!(items[0], json!({ "owner": "Me", "task": "Write the release notes", "due": "Thursday", "done": false }));
        assert_eq!(items[1]["done"], true);
        assert_eq!(items[2]["owner"], Value::Null);
        assert_eq!(parse_action_items("## Action items\n- None"), json!([]));
    }
}
