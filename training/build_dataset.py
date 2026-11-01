"""Merge pair files into mlx-lm chat format with the app's exact prompt.

    uv run build_dataset.py data/synthetic.jsonl data/disflqa.jsonl --disflqa-share 0.2

Writes data/train.jsonl and data/valid.jsonl. Your own recorded benchmark
clips are never used here; they stay the held-out test set.
"""

import argparse
import json
import random
from pathlib import Path

from common import chat_example

APPS = {"casual": ["Slack", "Messages", "Discord"], "prose": ["Mail", "Google Docs", "Notion"], "code": ["Visual Studio Code", "Terminal", "Cursor"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--out-dir", type=Path, default=Path("data"))
    parser.add_argument("--valid-share", type=float, default=0.05)
    parser.add_argument("--disflqa-share", type=float, default=0.2, help="cap Disfl-QA at this share of the final set")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    random.seed(args.seed)

    pairs = [json.loads(line) for path in args.inputs for line in path.read_text().splitlines() if line.strip()]
    disfl = [p for p in pairs if p["source"] == "disflqa"]
    other = [p for p in pairs if p["source"] != "disflqa"]
    cap = int(len(other) * args.disflqa_share / max(1e-9, 1 - args.disflqa_share))
    random.shuffle(disfl)
    pairs = other + disfl[:cap]
    random.shuffle(pairs)

    examples = []
    for p in pairs:
        style = p.get("style", "prose")
        # Show the app name some of the time so the model learns to use but not need it.
        app = random.choice(APPS[style]) if random.random() < 0.6 else ""
        examples.append(chat_example(p["transcript"], p["output"], style=style, vocabulary=p.get("vocabulary") or [], app_name=app))

    n_valid = max(1, int(len(examples) * args.valid_share))
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, rows in (("valid", examples[:n_valid]), ("train", examples[n_valid:])):
        with (args.out_dir / f"{name}.jsonl").open("w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
    print(f"{len(examples) - n_valid} train, {n_valid} valid ({len(other)} synthetic, {min(cap, len(disfl))} Disfl-QA)")


if __name__ == "__main__":
    main()
