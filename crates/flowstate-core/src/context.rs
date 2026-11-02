//! What's on screen when the user dictates, and the writing style it implies.

use serde::{Deserialize, Serialize};

/// Live context captured by the app shell right before dictation starts.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct DictationContext {
    /// macOS bundle id (`com.tinyspeck.slackmacgap`) or Windows exe name (`slack.exe`).
    pub app_id: String,
    pub app_name: String,
    pub window_title: String,
    /// Browser URL, when the shell can read it.
    pub url: Option<String>,
    /// Text already in the focused field, up to the cursor.
    pub text_before: String,
    /// A style the user picked for this app in settings. Wins over the
    /// style guessed from the app and URL.
    pub style: Option<Style>,
}

/// How much of the on-screen text to show the cleanup model.
const CONTEXT_CHARS: usize = 600;

impl DictationContext {
    pub fn style(&self) -> Style {
        self.style.unwrap_or_else(|| Style::for_app(&self.app_id, self.url.as_deref()))
    }

    /// The tail of the field text, trimmed to a sane size on a char boundary.
    pub fn recent_text(&self) -> &str {
        let text = self.text_before.as_str();
        if text.len() <= CONTEXT_CHARS {
            return text;
        }
        let mut start = text.len() - CONTEXT_CHARS;
        while !text.is_char_boundary(start) {
            start += 1;
        }
        &text[start..]
    }

    /// Everything the vocabulary index should scan for known terms.
    pub fn searchable(&self) -> String {
        format!("{}\n{}\n{}", self.window_title, self.url.as_deref().unwrap_or(""), self.recent_text())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Style {
    /// Chat apps: relaxed punctuation, no forced capitalization of fragments.
    Casual,
    /// Email and documents: full sentences and paragraphs.
    Prose,
    /// Editors, terminals and coding agents: keep identifiers, paths and
    /// symbols exactly; no sentence-ifying of commands.
    Code,
}

const CASUAL_APPS: &[&str] = &[
    "com.tinyspeck.slackmacgap",
    "com.apple.mobilesms",
    "net.whatsapp.whatsapp",
    "com.hnc.discord",
    "ru.keepcoder.telegram",
    "org.whispersystems.signal-desktop",
    "com.facebook.archon",
    "slack.exe",
    "discord.exe",
    "whatsapp.exe",
    "telegram.exe",
];

const CODE_APPS: &[&str] = &[
    "com.microsoft.vscode",
    "com.todesktop.230313mzl4w4u92", // Cursor
    "dev.zed.zed",
    "com.apple.dt.xcode",
    "com.apple.terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "dev.warp.warp-stable",
    "net.kovidgoyal.kitty",
    "io.alacritty",
    "code.exe",
    "cursor.exe",
    "windowsterminal.exe",
    "wt.exe",
];

const CASUAL_SITES: &[&str] = &["slack.com", "discord.com", "web.whatsapp.com", "messages.google.com", "x.com"];
const CODE_SITES: &[&str] = &["github.com", "gitlab.com", "claude.ai/code", "replit.com", "codesandbox.io"];

impl Style {
    pub fn for_app(app_id: &str, url: Option<&str>) -> Style {
        let app = app_id.to_lowercase();
        if let Some(url) = url {
            if CODE_SITES.iter().any(|s| url.contains(s)) {
                return Style::Code;
            }
            if CASUAL_SITES.iter().any(|s| url.contains(s)) {
                return Style::Casual;
            }
        }
        if CODE_APPS.contains(&app.as_str()) || app.starts_with("com.jetbrains.") {
            Style::Code
        } else if CASUAL_APPS.contains(&app.as_str()) {
            Style::Casual
        } else {
            Style::Prose
        }
    }

    pub fn instructions(self) -> &'static str {
        match self {
            Style::Casual => "casual chat message: relaxed and conversational; short messages need no trailing period",
            Style::Prose => "written prose such as email or a document: complete sentences and paragraphs",
            Style::Code => "coding tool or terminal: keep file names, identifiers, commands and symbols exactly as spoken terms suggest (e.g. snake_case, camelCase, dotted paths); plain sentences for instructions to a coding agent",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_style_by_app_and_url() {
        assert_eq!(Style::for_app("com.tinyspeck.slackmacgap", None), Style::Casual);
        assert_eq!(Style::for_app("com.jetbrains.intellij", None), Style::Code);
        assert_eq!(Style::for_app("com.apple.mail", None), Style::Prose);
        assert_eq!(Style::for_app("com.google.Chrome", Some("https://github.com/x/y/pull/1")), Style::Code);
        assert_eq!(Style::for_app("com.google.Chrome", Some("https://mail.google.com/")), Style::Prose);
        assert_eq!(Style::for_app("Slack.exe", None), Style::Casual);
    }

    #[test]
    fn chosen_style_wins_over_the_app() {
        let slack = DictationContext { app_id: "com.tinyspeck.slackmacgap".into(), ..Default::default() };
        assert_eq!(slack.style(), Style::Casual);
        assert_eq!(DictationContext { style: Some(Style::Prose), ..slack.clone() }.style(), Style::Prose);
        let browser = DictationContext { app_id: "com.google.Chrome".into(), url: Some("https://github.com/".into()), style: Some(Style::Casual), ..Default::default() };
        assert_eq!(browser.style(), Style::Casual);
    }

    #[test]
    fn recent_text_respects_char_boundaries() {
        let ctx = DictationContext { text_before: "é".repeat(400), ..Default::default() };
        let tail = ctx.recent_text();
        assert!(tail.len() <= CONTEXT_CHARS);
        assert!(tail.chars().all(|c| c == 'é'));
    }
}
