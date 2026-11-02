"""Convert the SottoASR transcript cleanup set (MIT) into cleanup pairs.

juanquivilla/sotto-transcript-cleanup has ~125k short synthetic pairs:
lowercase, unpunctuated ASR-style input with fillers, self-corrections,
false starts, misheard terms and dictation commands. Rows aren't labelled
by category, so a rough one is guessed from the input. Pairs that reword
("gonna" -> "going to") or add words fail the faithfulness check and are
dropped.

    uv run python -I prepare_sotto.py --out data/sotto/pairs.jsonl
"""

import argparse
import collections
import json
import re
import sys
from pathlib import Path

from huggingface_hub import snapshot_download

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import faithful, words  # noqa: E402

FIX_CUES = re.compile(r"\b(no wait|wait no|actually|i mean|sorry|scratch that|or rather|make that)\b")
LIST_CUES = re.compile(r"\b(first|second|step one|number one|bullet|new line|new paragraph)\b")
FILLERS = re.compile(r"\b(um|uh|uhm|er|ah|like|you know|basically)\b")


def guess_category(messy: str, clean: str) -> str:
    m = messy.lower()
    if "scratch that" in m:
        return "scratch"
    if FIX_CUES.search(m):
        return "backtrack_near"
    if LIST_CUES.search(m) or "\n" in clean:
        return "lists"
    if FILLERS.search(m):
        return "fillers"
    if words(messy) == words(clean):
        return "already_clean"
    return "restarts"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=Path("data/sotto/pairs.jsonl"))
    args = parser.parse_args()
    raw = args.out.parent / "raw"
    snapshot_download("juanquivilla/sotto-transcript-cleanup", repo_type="dataset", local_dir=raw,
                      allow_patterns=["*.jsonl", "README.md"])

    kept, dropped, seen = collections.Counter(), collections.Counter(), set()
    with args.out.open("w") as f:
        for name in ("train.jsonl", "val.jsonl"):
            for line in (raw / name).read_text().splitlines():
                row = json.loads(line)
                messy, clean = row.get("input", "").strip(), row.get("output", "").strip()
                if messy in seen:
                    dropped["duplicate"] += 1
                    continue
                seen.add(messy)
                why = "markdown" if "**" in clean else faithful(messy, clean)
                if why:
                    dropped[why.split(":")[0]] += 1
                    continue
                category = guess_category(messy, clean)
                style = "code" if re.search(r"[a-z][A-Z]|\w\.\w{2,4}\b|_", clean) else "casual" if len(clean) < 60 else "prose"
                f.write(json.dumps({"source": "sotto", "category": category, "style": style,
                                    "transcript": messy, "output": clean, "vocabulary": []}) + "\n")
                kept[category] += 1
    print(f"wrote {sum(kept.values())} pairs to {args.out}: {dict(kept)}; dropped {dict(dropped)}")


if __name__ == "__main__":
    main()
