"""Turn validation pairs into a flowstate-bench manifest for cleanup-only runs.

The TTS clips are only a handful of sentences; this gives a bigger number
on pairs the model never trained on. Categories map onto the bench's:
corrections, restarts and retractions count as "repair".

    uv run python -I valid_to_manifest.py data/valid_pairs.jsonl --count 200 \\
        --out data/bench-valid200.jsonl --vocab-out data/bench-valid200-vocab.txt
    cargo run --release -p flowstate-bench -- --manifest training/data/bench-valid200.jsonl \\
        --vocab training/data/bench-valid200-vocab.txt --llama-server build/llama-server --local-model model.gguf
"""

import argparse
import json
import random
from pathlib import Path

BENCH_CATEGORY = {"backtrack_near": "repair", "backtrack_far": "repair", "scratch": "repair", "restarts": "repair",
                  "vocabulary": "vocab", "fillers": "filler"}
APP_IDS = {"Slack": "com.tinyspeck.slackmacgap", "Messages": "com.apple.MobileSMS", "Discord": "com.hnc.Discord",
           "Mail": "com.apple.mail", "Google Docs": "com.google.Chrome", "Notion": "notion.id",
           "Visual Studio Code": "com.microsoft.VSCode", "Terminal": "com.apple.Terminal",
           "Cursor": "com.todesktop.230313mzl4w4u92"}
# Without an app name the style still has to match the pair's.
STYLE_APP = {"casual": "com.tinyspeck.slackmacgap", "prose": "com.apple.mail", "code": "com.microsoft.VSCode"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pairs", type=Path)
    parser.add_argument("--count", type=int, default=200)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--vocab-out", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    pairs = [json.loads(l) for l in args.pairs.read_text().splitlines() if l.strip()]
    random.Random(args.seed).shuffle(pairs)
    # The phonetic index panics on some non-ASCII input (rphonetic slices
    # inside a multi-byte char), so keep the slice ASCII for now.
    pairs = [p for p in pairs if p["transcript"].isascii()]
    vocab: dict[str, None] = {}
    with args.out.open("w") as f:
        for i, p in enumerate(pairs[: args.count]):
            terms = [t for t in p.get("vocabulary") or [] if t in p["output"]]
            vocab.update(dict.fromkeys(terms))
            app = p.get("app", "")
            context = {"app_id": APP_IDS.get(app, STYLE_APP[p.get("style", "prose")]), "app_name": app}
            f.write(json.dumps({
                "id": f"valid-{i:03d}-{p['category']}", "category": BENCH_CATEGORY.get(p["category"], p["category"]),
                "transcript": p["transcript"], "reference": p["output"], "terms": terms, "context": context,
                "source": p["source"],
            }) + "\n")
    args.vocab_out.write_text("".join(f"{t}\n" for t in vocab))
    print(f"wrote {min(args.count, len(pairs))} clips to {args.out}, {len(vocab)} vocabulary terms to {args.vocab_out}")


if __name__ == "__main__":
    main()
