"""Shared formatting: training examples must look exactly like what the app
sends the cleanup model, so this mirrors crates/flowstate-core/src/cleanup/prompt.rs.

Also holds the faithfulness check every data source runs its pairs through:
a clean output may drop, reorder and repunctuate the speaker's words, but
not add new ones."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYSTEM_PROMPT = (ROOT / "prompts" / "cleanup_system.md").read_text()

STYLES = {
    "casual": "casual chat message: relaxed and conversational; short messages need no trailing period",
    "prose": "written prose such as email or a document: complete sentences and paragraphs",
    "code": "coding tool or terminal: keep file names, identifiers, commands and symbols exactly as spoken terms suggest (e.g. snake_case, camelCase, dotted paths); plain sentences for instructions to a coding agent",
}


def user_message(transcript: str, style: str = "prose", vocabulary: list[str] | None = None,
                 app_name: str = "", text_before: str = "",
                 likely_fixes: list[tuple[str, str]] | None = None) -> str:
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
    if likely_fixes:
        lines = "\n".join(f'"{heard}" → {term}' for heard, term in likely_fixes)
        parts.append(f"<likely_fixes>\n{lines}\n</likely_fixes>")
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


NUMBER_WORDS = set(
    "zero oh one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen "
    "seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million "
    "billion trillion point percent dollar dollars cent cents half quarter first second third fourth fifth sixth "
    "seventh eighth ninth tenth eleventh twelfth twentieth thirtieth hundredth".split()
)
# Short pieces number formatting produces: 3rd, 9am, 5k, 1990s.
NUMBER_SUFFIXES = {"st", "nd", "rd", "th", "am", "pm", "a", "p", "k", "m", "s"}
REFUSALS = re.compile(r"\b(i can(no|')t (help|assist|do)|i'm sorry, but|as an ai|i am unable to|language model)\b", re.I)


def words(text: str) -> list[str]:
    """Lowercased alphanumeric words; apostrophes dropped so lets == let's."""
    text = text.lower().replace("'", "").replace("’", "")
    return [w for w in re.split(r"[^0-9a-z]+", text) if w]


def novel_words(transcript: str, output: str, vocabulary: list[str] | None = None) -> list[str]:
    """Output words the speaker never said, allowing for number formatting
    (twenty five -> 25), merged pieces (pg vector -> pgvector) and
    vocabulary spellings."""
    said = set(words(transcript))
    for term in vocabulary or []:
        said.update(words(term))
    joined = "".join(words(transcript))
    numeric = bool(said & NUMBER_WORDS) or any(any(c.isdigit() for c in w) for w in said)
    novel = []
    for w in words(output):
        if w in said or (len(w) > 3 and w in joined):
            continue
        if numeric and (any(c.isdigit() for c in w) or w in NUMBER_SUFFIXES):
            continue
        novel.append(w)
    return novel


def faithful(transcript: str, output: str, vocabulary: list[str] | None = None, max_ratio: float = 1.3) -> str | None:
    """Why a pair is unusable as training data, or None if it's fine."""
    transcript, output = transcript.strip(), output.strip()
    if not transcript or not output:
        return "empty"
    if len(output) > len(transcript) * max_ratio + 10:
        return "output longer than input"
    if REFUSALS.search(output) and not REFUSALS.search(transcript):
        return "refusal"
    novel = novel_words(transcript, output, vocabulary)
    if novel:
        return "new words: " + " ".join(novel[:5])
    return None
