"""Shared formatting: training examples must look exactly like what the app
sends the cleanup model, so this mirrors crates/flowstate-core/src/cleanup/prompt.rs."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYSTEM_PROMPT = (ROOT / "prompts" / "cleanup_system.md").read_text()

STYLES = {
    "casual": "casual chat message: relaxed and conversational; short messages need no trailing period",
    "prose": "written prose such as email or a document: complete sentences and paragraphs",
    "code": "coding tool or terminal: keep file names, identifiers, commands and symbols exactly as spoken terms suggest (e.g. snake_case, camelCase, dotted paths); plain sentences for instructions to a coding agent",
}


def user_message(transcript: str, style: str = "prose", vocabulary: list[str] | None = None,
                 app_name: str = "", text_before: str = "") -> str:
    parts = []
    if app_name or text_before:
        parts.append("<context>")
        if app_name:
            parts.append(f"App: {app_name}")
        if text_before:
            parts.append(f"Text before cursor: {text_before}")
        parts.append("</context>")
    parts.append(f"<style>{STYLES[style]}</style>")
    if vocabulary:
        parts.append(f"<vocabulary>{', '.join(vocabulary[:40])}</vocabulary>")
    parts.append(f"<transcript>{transcript}</transcript>")
    return "\n".join(parts)


def chat_example(transcript: str, output: str, **kwargs) -> dict:
    return {
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_message(transcript, **kwargs)},
            {"role": "assistant", "content": output},
        ]
    }
