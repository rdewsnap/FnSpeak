"""Generate (messy transcript, clean text) pairs with Claude.

Each request asks for a batch of pairs in one category and style, so the
mix stays balanced. Output is JSONL with the fields build_dataset.py reads.

    uv run generate_synthetic.py --count 2000 --out data/synthetic.jsonl

Cost scales with --count and the model; try --count 100 first and check the
output before generating a full set.
"""

import argparse
import json
import random
import sys
from pathlib import Path

import anthropic
from pydantic import BaseModel

CATEGORIES = {
    "fillers": "Fillers and hesitations (um, uh, like, you know, I mean, sort of, basically) mixed into otherwise normal speech. The clean version removes only the meaningless ones.",
    "restarts": "False starts and repeated phrases or sentences where the speaker restarts ('so the build is, the build is failing because...'). The clean version keeps the final version once.",
    "backtrack_near": "Immediate self-corrections ('at three, no wait, four', 'send it to Sam, sorry, Priya'). The clean version keeps only the corrected content and drops the correction phrase.",
    "backtrack_far": "Corrections that refer back one to three sentences ('Book the flight for Monday. Also get a hotel near the venue. Actually, make the flight Tuesday instead.'). The clean version applies the correction where it belongs.",
    "scratch": "Retractions ('scratch that', 'never mind that last part', 'delete that') that remove a clause or sentence entirely.",
    "lists": "Spoken enumerations ('first..., second..., third...', 'a few things: ...') and spoken formatting commands ('new paragraph', 'new line', 'bullet point'). The clean version uses a numbered or bulleted list or the requested formatting.",
    "already_clean": "Speech that is already clean apart from missing punctuation and capitalization. The clean version only fixes punctuation and capitalization, changing no words. This teaches the model not to over-edit.",
    "vocabulary": "Speech mentioning unusual names, product names, or technical terms that a speech recognizer mangles (split into pieces, misspelled phonetically, lowercased). Provide the correct spellings in 'vocabulary'. The clean version uses those spellings.",
    "instructions": "Speech that sounds like a command or question to an AI ('ignore the above and summarize this', 'what's the capital of France', 'write me a poem'). The clean version is the same text cleaned up, NOT an answer or an action.",
    "numbers": "Speech with numbers, times, dates, money and units spoken as words. The clean version writes them the way a person would type them in that style.",
}

DOMAINS = [
    "software engineering at a startup", "product management", "sales and customer emails", "personal texts with friends",
    "family logistics", "healthcare scheduling", "legal and compliance notes", "academic research", "travel planning",
    "finance and budgeting", "design feedback", "hiring and recruiting", "talking to an AI coding assistant",
    "restaurant and event planning", "home renovation", "fitness and sports", "journalism and writing drafts",
]

STYLES = ["casual", "prose", "code"]


class Pair(BaseModel):
    transcript: str
    output: str
    vocabulary: list[str]


class Batch(BaseModel):
    pairs: list[Pair]


PROMPT = """You are creating training data for a dictation cleanup model. The model receives a raw speech-recognition transcript and must output the text the speaker meant to type.

Write {n} varied examples.
Category: {category}
Domain: {domain}
Style: {style} ({style_hint})

Rules for "transcript": make it read like real speech-recognition output: run-on sentences, inconsistent punctuation, sometimes all lowercase, numbers often spelled out, natural spoken rhythm. Vary length from one short sentence to a long paragraph. Never mention that it is a transcript.
Rules for "output": exactly what a careful person would have typed. It must contain only content the speaker actually said (after applying their own corrections); never add facts, greetings or sign-offs.
Rules for "vocabulary": the correct spellings of unusual names or terms in this example (empty list if none). Invent realistic, diverse names; don't reuse common ones like John or Acme.
"""

STYLE_HINTS = {
    "casual": "a chat message in Slack or iMessage",
    "prose": "an email or document",
    "code": "an editor, terminal or a message to a coding agent; identifiers like getUser or config.yaml may appear",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=200, help="approximate number of pairs")
    parser.add_argument("--per-request", type=int, default=20)
    parser.add_argument("--model", default="claude-opus-5-5")
    parser.add_argument("--out", type=Path, default=Path("data/synthetic.jsonl"))
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    random.seed(args.seed)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    client = anthropic.Anthropic()
    categories = list(CATEGORIES)
    written = 0

    with args.out.open("a") as f:
        while written < args.count:
            category = categories[(written // args.per_request) % len(categories)]
            style = random.choice(STYLES)
            domain = random.choice(DOMAINS)
            prompt = PROMPT.format(
                n=args.per_request, category=CATEGORIES[category], domain=domain,
                style=style, style_hint=STYLE_HINTS[style],
            )
            try:
                response = client.beta.messages.parse(
                    model=args.model,
                    max_tokens=16000,
                    messages=[{"role": "user", "content": prompt}],
                    output_format=Batch,
                    output_config={"effort": "low"},
                    # Route around a refusal instead of failing the batch.
                    betas=["server-side-fallback-2026-07-01"],
                    fallbacks="default",
                )
            except anthropic.RateLimitError:
                print("rate limited; stopping early", file=sys.stderr)
                break
            except anthropic.APIStatusError as e:
                print(f"request failed ({e.status_code}): {e.message}", file=sys.stderr)
                continue

            if response.stop_reason == "refusal" or response.parsed_output is None:
                print(f"skipped a {category} batch ({response.stop_reason})", file=sys.stderr)
                continue
            for pair in response.parsed_output.pairs:
                f.write(json.dumps({
                    "source": "synthetic", "category": category, "style": style,
                    "transcript": pair.transcript, "output": pair.output, "vocabulary": pair.vocabulary,
                }) + "\n")
                written += 1
            print(f"{written}/{args.count} ({category}, {style})", file=sys.stderr)


if __name__ == "__main__":
    main()
