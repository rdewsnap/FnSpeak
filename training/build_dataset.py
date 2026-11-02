"""Merge pair files into mlx-lm chat format with the app's exact prompt.

    uv run build_dataset.py data/*/pairs.jsonl \\
        --cap corrupt=11000 local=3500 aawaaz=4000 sotto=6000 disflqa=2500

--cap limits each source (matched on the part of "source" before any
colon) so no single set dominates. Writes data/train.jsonl and
data/valid.jsonl, plus data/valid_pairs.jsonl with the raw validation
pairs for benchmarking.

Prompts are built the way the app builds them: the app sends the user's
whole vocabulary (up to 40 terms) with every dictation, plus <likely_fixes>
when the phonetic index matched something, so examples get unrelated
vocabulary terms mixed in and sometimes a likely fix.

Held out: anything in bench/ (clip text and vocabulary terms) is dropped
from training, so benchmark numbers stay honest.
"""

import argparse
import collections
import json
import random
import re
from pathlib import Path

from common import ROOT, chat_example

APPS = {"casual": ["Slack", "Messages", "Discord"], "prose": ["Mail", "Google Docs", "Notion"], "code": ["Visual Studio Code", "Terminal", "Cursor"]}


def bench_holdout() -> tuple[set[str], list[str]]:
    """Vocabulary terms and reference sentences from bench/, lowercased."""
    terms, refs = set(), []
    bench = ROOT / "bench"
    for path in bench.glob("*.jsonl"):
        for line in path.read_text().splitlines():
            if not line.strip() or line.lstrip().startswith("//"):
                continue
            clip = json.loads(line)
            terms.update(t.lower() for t in clip.get("terms", []))
            refs.append(clip.get("reference", "").lower())
    for path in bench.glob("vocab*.txt"):
        terms.update(l.strip().lower() for l in path.read_text().splitlines() if l.strip() and not l.startswith("#"))
    return terms, [r for r in refs if r]


def touches_bench(pair: dict, terms: set[str], refs: list[str]) -> bool:
    text = f"{pair['transcript']} {pair['output']} {' '.join(pair.get('vocabulary') or [])}".lower()
    squashed = re.sub(r"[^a-z0-9]", "", text)
    if any(re.sub(r"[^a-z0-9]", "", t) in squashed for t in terms):
        return True
    out = pair["output"].lower()
    return any(r[:40] in out for r in refs)


def parse_caps(items: list[str]) -> dict[str, int]:
    caps = {}
    for item in items:
        name, _, n = item.partition("=")
        caps[name] = int(n)
    return caps


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--out-dir", type=Path, default=Path("data"))
    parser.add_argument("--valid-share", type=float, default=0.05)
    parser.add_argument("--cap", nargs="*", default=[], help="source=N limits, e.g. disflqa=2500")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    caps = parse_caps(args.cap)

    terms, refs = bench_holdout()
    by_source: dict[str, list[dict]] = collections.defaultdict(list)
    held_out = 0
    for path in args.inputs:
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            pair = json.loads(line)
            if touches_bench(pair, terms, refs):
                held_out += 1
                continue
            by_source[pair["source"].split(":")[0]].append(pair)

    pairs = []
    for source, rows in sorted(by_source.items()):
        rng.shuffle(rows)
        pairs.extend(rows[: caps.get(source, len(rows))])
    rng.shuffle(pairs)

    # Pool of real-looking terms to pad vocabulary lists with.
    pool = sorted({t for p in pairs for t in p.get("vocabulary") or [] if 2 < len(t) < 30})

    examples, raw = [], []
    for p in pairs:
        style = p.get("style", "prose")
        vocab = list(p.get("vocabulary") or [])
        if pool and rng.random() < 0.5:
            vocab += rng.sample(pool, k=min(len(pool), rng.randint(1, 15)))
            rng.shuffle(vocab)
        vocab = list(dict.fromkeys(vocab))
        fixes = [tuple(f) for f in p.get("fixes") or []] if rng.random() < 0.5 else []
        # Show the app name some of the time so the model learns to use but not need it.
        app = rng.choice(APPS[style]) if rng.random() < 0.6 else ""
        # Occasionally there's text on screen; the model must never copy it.
        before = rng.choice(pairs)["output"][-200:] if rng.random() < 0.1 else ""
        examples.append(chat_example(p["transcript"], p["output"], style=style, vocabulary=vocab,
                                     app_name=app, text_before=before, likely_fixes=fixes))
        raw.append({**p, "style": style, "app": app, "prompt_vocabulary": vocab})

    n_valid = max(1, int(len(examples) * args.valid_share))
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, rows in (("valid", examples[:n_valid]), ("train", examples[n_valid:]), ("valid_pairs", raw[:n_valid])):
        with (args.out_dir / f"{name}.jsonl").open("w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")

    sources = collections.Counter(p["source"].split(":")[0] for p in pairs)
    categories = collections.Counter(p["category"] for p in pairs)
    print(f"{len(examples) - n_valid} train, {n_valid} valid; dropped {held_out} touching bench/")
    print(f"sources: {dict(sources.most_common())}")
    print(f"categories: {dict(categories.most_common())}")


if __name__ == "__main__":
    main()
