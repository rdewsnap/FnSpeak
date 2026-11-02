"""Convert Google's Disfl-QA (CC BY 4.0) into cleanup pairs.

Disfl-QA has ~12k questions with human-written disfluencies, over 90% of
them corrections or restarts. They're all questions, so they supplement the
synthetic set rather than replace it.

    uv run python -I prepare_disflqa.py --out data/disflqa/pairs.jsonl

All three splits are used; the held-out test set is your own recordings.
"""

import argparse
import json
from pathlib import Path

from datasets import load_dataset


def pick(row: dict, *needles: str) -> str:
    """Find a column by keywords; the dataset's column names have varied."""
    for key, value in row.items():
        if all(n in key.lower() for n in needles) and isinstance(value, str):
            return value
    raise KeyError(f"no column matching {needles}: {list(row)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=Path("data/disflqa/pairs.jsonl"))
    args = parser.parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)

    count = 0
    with args.out.open("w") as f:
        for split in ("train", "validation", "test"):
            rows = load_dataset("google-research-datasets/disfl_qa", split=split, cache_dir=str(args.out.parent / "hf"))
            for row in rows:
                messy, clean = pick(row, "disfluent").strip(), pick(row, "original").strip()
                if not messy or not clean or messy == "#VALUE!":
                    continue
                f.write(json.dumps({
                    "source": "disflqa", "category": "backtrack_near", "style": "prose",
                    "transcript": messy, "output": clean, "vocabulary": [],
                }) + "\n")
                count += 1
    print(f"wrote {count} pairs to {args.out}")


if __name__ == "__main__":
    main()
