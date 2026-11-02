//! A Flowstate server (Flowstate Cloud or self-hosted) as the cleanup
//! backend. Dictation cleanup goes through its OpenAI-style endpoint, but
//! that endpoint only ever cleans up, whatever the system prompt says, so
//! meeting summaries go to `/summarize` instead. The server can't title
//! notes; those fall back to the note's first words.

use super::{Cleaner, CleanupError, CleanupRequest, Llm, OpenAiCompatCleaner};
use crate::summary::SUMMARY_PROMPT;
use serde_json::{json, Value};
use std::time::Duration;

/// The server runs a long-context hosted model.
const CONTEXT_TOKENS: usize = 128_000;
const SUMMARY_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Clone)]
pub struct FlowstateCleaner {
    cleanup: OpenAiCompatCleaner,
    base_url: String,
    token: String,
    http: reqwest::blocking::Client,
}

impl FlowstateCleaner {
    /// `base_url` is the server's API root, e.g. `https://example.com/v1`.
    pub fn new(base_url: impl Into<String>, token: impl Into<String>) -> Result<Self, CleanupError> {
        let base_url = base_url.into().trim_end_matches('/').to_string();
        let token = token.into();
        // The server picks the model; this name only shows up in logs.
        let cleanup = OpenAiCompatCleaner::new(&base_url, Some(token.clone()), "flowstate")?.with_context_tokens(CONTEXT_TOKENS);
        let http = reqwest::blocking::Client::builder().build().map_err(|e| CleanupError::Load(e.to_string()))?;
        Ok(FlowstateCleaner { cleanup, base_url, token, http })
    }

    fn summarize(&self, input: &str) -> Result<String, CleanupError> {
        let resp = self
            .http
            .post(format!("{}/summarize", self.base_url))
            .bearer_auth(&self.token)
            .timeout(SUMMARY_TIMEOUT)
            .json(&json!({ "input": input }))
            .send()
            .map_err(|e| CleanupError::Request(e.to_string()))?;
        let status = resp.status();
        let body: Value = resp.json().map_err(|e| CleanupError::Request(e.to_string()))?;
        if !status.is_success() {
            let message = body["error"]["message"].as_str().unwrap_or("no error message");
            return Err(CleanupError::Request(format!("HTTP {status}: {message}")));
        }
        body["summary_md"]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| CleanupError::Request("the server's answer had no summary".into()))
    }
}

impl Cleaner for FlowstateCleaner {
    fn name(&self) -> String {
        "flowstate".into()
    }

    fn clean(&mut self, req: &CleanupRequest<'_>) -> Result<String, CleanupError> {
        self.cleanup.clean(req)
    }

    fn llm(&self) -> Option<Box<dyn Llm>> {
        Some(Box::new(self.clone()))
    }
}

impl Llm for FlowstateCleaner {
    fn name(&self) -> String {
        Cleaner::name(self)
    }

    fn context_tokens(&self) -> usize {
        CONTEXT_TOKENS
    }

    fn complete(&self, system: &str, user: &str, _max_tokens: u32) -> Result<String, CleanupError> {
        if system == SUMMARY_PROMPT {
            self.summarize(user)
        } else {
            Err(CleanupError::Refused)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::summary::NOTE_TITLE_PROMPT;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;
    use std::sync::mpsc;

    /// Answers one HTTP request with `body` and hands back what was asked.
    fn one_shot_server(body: &'static str) -> (String, mpsc::Receiver<(String, String)>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/v1", listener.local_addr().unwrap());
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut head = String::new();
            let mut length = 0;
            loop {
                let mut line = String::new();
                reader.read_line(&mut line).unwrap();
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = v.trim().parse().unwrap();
                }
                if line == "\r\n" {
                    break;
                }
                head.push_str(&line);
            }
            let mut request = vec![0; length];
            reader.read_exact(&mut request).unwrap();
            tx.send((head, String::from_utf8(request).unwrap())).unwrap();
            let reply = format!("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{body}", body.len());
            stream.write_all(reply.as_bytes()).unwrap();
        });
        (url, rx)
    }

    #[test]
    fn summaries_go_to_the_summarize_endpoint() {
        let (url, rx) = one_shot_server(r###"{"summary_md": "## Summary\n- Ship it", "action_items": []}"###);
        let cleaner = FlowstateCleaner::new(url, "fst_test").unwrap();
        let llm = cleaner.llm().unwrap();
        assert_eq!(llm.complete(SUMMARY_PROMPT, "<meeting>\n</meeting>\n<transcript>\nhi\n</transcript>", 512).unwrap(), "## Summary\n- Ship it");
        let (head, body) = rx.recv().unwrap();
        assert!(head.starts_with("POST /v1/summarize "));
        assert!(head.to_ascii_lowercase().contains("authorization: bearer fst_test"));
        let sent: Value = serde_json::from_str(&body).unwrap();
        assert!(sent["input"].as_str().unwrap().starts_with("<meeting>"));
    }

    #[test]
    fn other_prompts_are_declined_without_a_request() {
        let cleaner = FlowstateCleaner::new("http://127.0.0.1:9/v1", "fst_test").unwrap();
        assert!(matches!(cleaner.llm().unwrap().complete(NOTE_TITLE_PROMPT, "<note>x</note>", 32), Err(CleanupError::Refused)));
    }
}
