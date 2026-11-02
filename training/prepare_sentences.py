"""Collect clean passages for corrupt.py to turn into messy transcripts.

Sources, all usable commercially:
  - WikiText-2 (Salesforce/wikitext, CC BY-SA 3.0): encyclopedic prose.
  - OpenAssistant oasst1 (Apache 2.0): English prompts people typed to an
    assistant, i.e. questions and commands, the casual register and the text
    that must be cleaned, never answered.
  - Dolly 15k (databricks/databricks-dolly-15k, CC BY-SA 3.0): human-written
    instructions and short answers.

Files are downloaded into data/sentences/ and only parsed, never executed.

    uv run python -I prepare_sentences.py --out data/sentences/passages.jsonl
"""

import argparse
import gzip
import json
import random
import re
from pathlib import Path

import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download

SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=[A-Z])")


def detok_wikitext(line: str) -> str:
    line = line.replace(" @-@ ", "-").replace(" @,@ ", ",").replace(" @.@ ", ".")
    line = re.sub(r" ([,.;:!?%)\]])", r"\1", line)
    line = re.sub(r"([(\[$]) ", r"\1", line)
    line = re.sub(r" (n't|'s|'re|'ve|'ll|'d|'m)\b", r"\1", line)
    line = line.replace("  ", " ")
    return line.strip()


def usable(text: str, lo: int = 4, hi: int = 60) -> bool:
    n = len(text.split())
    return (lo <= n <= hi and text.isascii() and "http" not in text and "\n" not in text
            and not re.search(r"[{}<>=_*#|\\`~^]", text) and text.count('"') % 2 == 0
            and not text.endswith((",", ":", ";", "-")) and not re.search(r"\b[A-Z]{2,}\W+[A-Z]{2,}\W+[A-Z]{2,}\b", text))


def wikitext(cache: Path, rng: random.Random) -> list[dict]:
    path = hf_hub_download("Salesforce/wikitext", "wikitext-2-raw-v1/train-00000-of-00001.parquet",
                           repo_type="dataset", cache_dir=cache)
    out = []
    for line in pq.read_table(path).column("text").to_pylist():
        line = line.strip()
        # Quotes are space-padded in WikiText and can't be reattached reliably.
        if not line or line.startswith("=") or '"' in line or " ' " in line:
            continue
        sentences = [s for s in SENTENCE_END.split(detok_wikitext(line)) if usable(s, 5, 35)]
        i = 0
        while i < len(sentences):
            k = rng.choice([1, 1, 2, 2, 3])
            out.append({"source": "wikitext", "register": "prose", "text": " ".join(sentences[i:i + k])})
            i += k
    return out


def oasst(cache: Path) -> list[dict]:
    path = hf_hub_download("OpenAssistant/oasst1", "2023-04-12_oasst_prompts.messages.jsonl.gz",
                           repo_type="dataset", cache_dir=cache)
    out = []
    with gzip.open(path, "rt") as f:
        for line in f:
            m = json.loads(line)
            text = " ".join(m.get("text", "").split())
            if m.get("lang") == "en" and m.get("role") == "prompter" and not m.get("deleted") and usable(text, 4, 60):
                out.append({"source": "oasst1", "register": "instruction", "text": text})
    return out


def dolly(cache: Path) -> list[dict]:
    path = hf_hub_download("databricks/databricks-dolly-15k", "databricks-dolly-15k.jsonl",
                           repo_type="dataset", cache_dir=cache)
    out = []
    for line in Path(path).read_text().splitlines():
        row = json.loads(line)
        for field, register in (("instruction", "instruction"), ("response", "prose")):
            text = " ".join(row.get(field, "").split())
            if usable(text, 4, 50):
                out.append({"source": "dolly", "register": register, "text": text})
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=Path("data/sentences/passages.jsonl"))
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    cache = args.out.parent / "hf"
    cache.mkdir(parents=True, exist_ok=True)

    rows = wikitext(cache, rng) + oasst(cache) + dolly(cache)
    seen, unique = set(), []
    for r in rows:
        if r["text"] not in seen:
            seen.add(r["text"])
            unique.append(r)
    with args.out.open("w") as f:
        for r in unique:
            f.write(json.dumps(r) + "\n")
    counts = {s: sum(r["source"] == s for r in unique) for s in ("wikitext", "oasst1", "dolly")}
    print(f"wrote {len(unique)} passages to {args.out}: {counts}")


if __name__ == "__main__":
    main()
