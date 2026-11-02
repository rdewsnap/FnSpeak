"""Convert the Aawaaz transcript cleanup set (MIT) into cleanup pairs.

shantanugoel/aawaaz-transcript-cleanup-dataset has ~23k synthetic
messy/clean pairs in twelve categories. Some categories restructure the
text into notes with headings, which Flowstate doesn't do, so pairs whose
output uses Markdown or words the speaker never said are dropped.

    uv run python -I prepare_aawaaz.py --out data/aawaaz/pairs.jsonl
"""

import argparse
import collections
import json
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import faithful  # noqa: E402

# file -> (category, style) in generate_synthetic.py terms
FILES = {
    "casual_conversation": ("fillers", "casual"),
    "self_corrections_heavy": ("backtrack_near", "prose"),
    "technical_code": ("vocabulary", "code"),
    "financial_business": ("numbers", "prose"),
    "academic_research": ("fillers", "prose"),
    "legal_contract": ("fillers", "prose"),
    "email_professional": ("fillers", "prose"),
    "medical_clinical": ("numbers", "prose"),
    "meeting_notes": ("lists", "prose"),
    "shopping_lists": ("lists", "casual"),
    "recipe_cooking": ("lists", "casual"),
    "creative_writing": ("already_clean", "prose"),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=Path("data/aawaaz/pairs.jsonl"))
    args = parser.parse_args()
    raw = args.out.parent / "raw"
    snapshot_download("shantanugoel/aawaaz-transcript-cleanup-dataset", repo_type="dataset", local_dir=raw,
                      allow_patterns=["*.jsonl", "README.md"])

    kept, dropped = collections.Counter(), collections.Counter()
    with args.out.open("w") as f:
        for name, (category, style) in FILES.items():
            for line in (raw / f"{name}.jsonl").read_text().splitlines():
                row = json.loads(line)
                messy, clean = row.get("input", "").strip(), row.get("output", "").strip()
                why = "markdown" if any(m in clean for m in ("**", "# ", "\n- ", "\n* ")) else faithful(messy, clean)
                if why:
                    dropped[why.split(":")[0]] += 1
                    continue
                f.write(json.dumps({"source": "aawaaz", "category": category, "style": style, "subset": name,
                                    "transcript": messy, "output": clean, "vocabulary": []}) + "\n")
                kept[name] += 1
    print(f"wrote {sum(kept.values())} pairs to {args.out}: {dict(kept)}; dropped {dict(dropped)}")


if __name__ == "__main__":
    main()
