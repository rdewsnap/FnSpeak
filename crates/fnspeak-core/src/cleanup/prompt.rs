use super::CleanupRequest;
use crate::vocab::HINT_SCORE;
use std::fmt::Write;

/// Shared with `training/` so the fine-tuned model sees the same instructions.
pub const SYSTEM_PROMPT: &str = include_str!("../../../../prompts/cleanup_system.md");

const MAX_VOCAB_IN_PROMPT: usize = 40;

pub fn build_user_message(req: &CleanupRequest<'_>) -> String {
    let mut msg = String::new();
    let ctx = req.context;

    if !ctx.app_name.is_empty() || !ctx.window_title.is_empty() || !ctx.text_before.is_empty() {
        msg.push_str("<context>\n");
        if !ctx.app_name.is_empty() {
            let _ = writeln!(msg, "App: {}", ctx.app_name);
        }
        if !ctx.window_title.is_empty() {
            let _ = writeln!(msg, "Window: {}", ctx.window_title);
        }
        let recent = ctx.recent_text().trim();
        if !recent.is_empty() {
            let _ = writeln!(msg, "Text before cursor: {recent}");
        }
        msg.push_str("</context>\n");
    }

    let _ = writeln!(msg, "<style>{}</style>", ctx.style().instructions());

    if !req.vocabulary.is_empty() {
        let terms: Vec<&str> = req.vocabulary.iter().take(MAX_VOCAB_IN_PROMPT).map(String::as_str).collect();
        let _ = writeln!(msg, "<vocabulary>{}</vocabulary>", terms.join(", "));
    }

    let fixes: Vec<String> = req
        .suggestions
        .iter()
        .filter(|s| s.score >= HINT_SCORE)
        .map(|s| format!("\"{}\" → {}", s.heard, s.term))
        .collect();
    if !fixes.is_empty() {
        let _ = writeln!(msg, "<likely_fixes>\n{}\n</likely_fixes>", fixes.join("\n"));
    }

    let _ = write!(msg, "<transcript>{}</transcript>", req.transcript);
    msg
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::DictationContext;
    use crate::vocab::Suggestion;

    #[test]
    fn message_includes_context_vocab_and_fixes() {
        let ctx = DictationContext {
            app_id: "com.tinyspeck.slackmacgap".into(),
            app_name: "Slack".into(),
            window_title: "#eng".into(),
            text_before: "did the deploy go out?".into(),
            ..Default::default()
        };
        let vocab = vec!["Kinju".to_string()];
        let suggestions = vec![Suggestion { start: 4, end: 10, heard: "kin ju".into(), term: "Kinju".into(), score: 0.97 }];
        let req = CleanupRequest { transcript: "yep kin ju is live", context: &ctx, vocabulary: &vocab, suggestions: &suggestions };
        let msg = build_user_message(&req);
        assert!(msg.contains("App: Slack"));
        assert!(msg.contains("casual chat"));
        assert!(msg.contains("<vocabulary>Kinju</vocabulary>"));
        assert!(msg.contains("\"kin ju\" → Kinju"));
        assert!(msg.ends_with("<transcript>yep kin ju is live</transcript>"));
    }

    #[test]
    fn style_override_reaches_the_prompt() {
        use crate::context::Style;
        let ctx = DictationContext { app_id: "com.tinyspeck.slackmacgap".into(), style: Some(Style::Code), ..Default::default() };
        let req = CleanupRequest { transcript: "run cargo test", context: &ctx, vocabulary: &[], suggestions: &[] };
        let msg = build_user_message(&req);
        assert!(msg.contains(Style::Code.instructions()));
        assert!(!msg.contains("casual chat"));
    }

    #[test]
    fn system_prompt_is_loaded() {
        assert!(SYSTEM_PROMPT.contains("Resolve self-corrections"));
    }
}
