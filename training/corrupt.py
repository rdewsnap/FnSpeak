"""Turn clean passages into realistic speech-recognition transcripts.

Each clean passage (from prepare_sentences.py) stays the target; the
transcript gets one to three corruptions a dictating person or a speech
recognizer would produce:

  fillers        um, uh, like, you know, I mean, sort of
  stutter        "th- the", "I I"
  repeat         a phrase said twice ("the build is, the build is")
  false_start    an abandoned start, then the clause again
  near_fix       an immediate correction ("at three, no wait, four")
  far_fix        a correction a sentence later ("Actually, make that Tuesday.")
  scratch        a clause followed by "scratch that"
  spoken_format  "new paragraph" / "new line" between sentences
  spell_numbers  digits spoken as words (24 -> twenty four)
  split_name     a name or term split and respelled ("val kyria"); the
                 correct spelling goes into the pair's vocabulary
  lowercase / no_punct  recognizer output without casing or punctuation

Every pair lists the corruptions applied, so results can be sliced by them,
and passes the same faithfulness check as the other sources. Output is
deterministic for a given --seed.

    uv run python -I corrupt.py data/sentences/passages.jsonl --count 12000 --out data/corrupt/pairs.jsonl
    uv run python -I corrupt.py --selftest
"""

import argparse
import collections
import json
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import faithful  # noqa: E402

FILLERS = ["um", "uh", "um", "uh", "like", "you know", "I mean", "sort of", "kind of", "basically", "uh, like", "um, so"]
NEAR_CUES = ["no wait", "sorry", "I mean", "no", "actually", "or rather", "no no", "wait, no", "uh, no"]
FAR_TEMPLATES = [
    "Actually, make that {t}.", "Wait, not {d}, {t}.", "Sorry, I meant {t}, not {d}.", "Oh, and change {d} to {t}.",
    "Correction, it should be {t} instead of {d}.", "Actually, it's {t}, not {d}.", "Scratch {d}, it's {t}.",
    "Wait, I said {d}. I meant {t}.",
]
SCRATCH_PHRASES = ["scratch that", "never mind, scratch that", "delete that", "actually, forget that last part",
                   "no, scratch that", "never mind that last part"]
WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
          "November", "December"]
STOPWORDS = set("""a an the and or but if then so of to in on at by for with from as is are was were be been being it its
this that these those he she they we you i his her their our your my me him them us not no do does did have has had
will would can could should may might must shall which who whom whose what when where why how there here than also
into onto over under about after before during between through up down out off very more most such only own same
just one""".split())

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
ORDINAL = {"one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth", "nine": "ninth",
           "twelve": "twelfth"}


# --- Numbers ---------------------------------------------------------------

def say_int(n: int) -> str:
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        rest = n % 100
        return ONES[n // 100] + " hundred" + ("" if rest == 0 else " " + say_int(rest))
    for size, name in ((10**9, "billion"), (10**6, "million"), (1000, "thousand")):
        if n >= size:
            rest = n % size
            return say_int(n // size) + " " + name + ("" if rest == 0 else " " + say_int(rest))
    raise ValueError(n)


def say_year(n: int) -> str:
    if 2000 <= n <= 2009:
        return say_int(n)
    hi, lo = divmod(n, 100)
    if lo == 0:
        return say_int(hi) + " hundred"
    return say_int(hi) + " " + ("oh " + ONES[lo] if lo < 10 else say_int(lo))


def say_ordinal(n: int) -> str:
    words = say_int(n).split()
    last = words[-1]
    if last in ORDINAL:
        words[-1] = ORDINAL[last]
    elif last.endswith("y"):
        words[-1] = last[:-1] + "ieth"
    else:
        words[-1] = last + "th"
    return " ".join(words)


NUMBER_TOKEN = re.compile(r"^(\$?)(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?(%|st|nd|rd|th|s)?$")


def say_number_token(token: str, rng: random.Random) -> str | None:
    """Spoken form of a numeric token (punctuation stripped), or None."""
    m = NUMBER_TOKEN.match(token)
    if not m:
        return None
    dollar, whole, frac, suffix = m.groups()
    n = int(whole.replace(",", ""))
    if n >= 10**12:
        return None
    if suffix in ("st", "nd", "rd", "th"):
        return say_ordinal(n)
    if not dollar and not frac and suffix in (None, "s") and 1100 <= n <= 2099 and "," not in whole:
        spoken = say_year(n)
        if suffix == "s":
            spoken = spoken[:-1] + "ies" if spoken.endswith("y") else spoken + "s"
        return spoken
    if suffix == "s":
        return None
    spoken = say_int(n)
    if frac:
        spoken += " point " + " ".join(ONES[int(d)] for d in frac[1:])
    if suffix == "%":
        spoken += " percent"
    if dollar:
        spoken += " dollars"
    return spoken


def spell_numbers(words: list[str], rng: random.Random) -> tuple[list[str], bool]:
    out, changed = [], False
    # Corrections can pack several words into one element; spell those too.
    for w in [piece for element in words for piece in element.split(" ")]:
        lead = re.match(r"^[(\"']*", w).group()
        trail = re.search(r"[)\"'.,;:!?]*$", w[len(lead):]).group()
        core = w[len(lead):len(w) - len(trail)] if trail else w[len(lead):]
        spoken = say_number_token(core, rng) if core else None
        if spoken:
            out.append(lead + spoken + trail)
            changed = True
        else:
            out.append(w)
    return out, changed


# --- Respelling ------------------------------------------------------------

RESPELL = [(r"ph", "f"), (r"ck", "k"), (r"c(?=[aou])", "k"), (r"qu", "kw"), (r"x", "ks"), (r"tion", "shun"),
           (r"ie", "ee"), (r"ei", "ay"), (r"wh", "w"), (r"kn", "n"), (r"gh", ""), (r"y$", "ee"), (r"([bdfglmnprst])\1", r"\1"),
           (r"eau", "oh"), (r"th", "t"), (r"z", "s"), (r"ou", "oo")]


def respell(term: str, rng: random.Random) -> str:
    """How a recognizer might write an unfamiliar word: phonetic, lowercased,
    sometimes split in two."""
    w = term.lower()
    rules = rng.sample(RESPELL, k=len(RESPELL))
    for pattern, repl in rules[: rng.randint(1, 4)]:
        w = re.sub(pattern, repl, w)
    if len(w) >= 6 and rng.random() < 0.6:
        # Split after a vowel near the middle: "valkyria" -> "val kyria".
        cut = [i for i in range(2, len(w) - 2) if w[i - 1] in "aeiou" and w[i] not in "aeiou"]
        if cut:
            i = min(cut, key=lambda c: abs(c - len(w) // 2))
            w = w[:i] + " " + w[i:]
    return w


# --- Corruptions -----------------------------------------------------------

def strip_word(w: str) -> str:
    return re.sub(r"^[^\w$]+|[^\w%]+$", "", w)


def sentences(text: str) -> list[str]:
    return [s for s in re.split(r"(?<=[.!?])\s+", text.strip()) if s]


class Corruptor:
    def __init__(self, passages: list[dict], seed: int):
        self.seed = seed
        self.passages = passages
        self.proper = sorted({strip_word(w) for p in passages[:20000] for w in p["text"].split()[1:]
                              if re.fullmatch(r"[A-Z][a-z]{3,}", strip_word(w)) and strip_word(w) not in WEEKDAYS + MONTHS})
        self.content = sorted({strip_word(w) for p in passages[:20000] for w in p["text"].split()
                               if re.fullmatch(r"[a-z]{4,}", strip_word(w)) and strip_word(w) not in STOPWORDS})

    # Pick a word to correct and a plausible wrong value for it.
    def slot(self, words: list[str], rng: random.Random, allow_common: bool = False) -> tuple[int, str] | None:
        """Pick a word to correct and a wrong value for it. Numbers, days,
        months and names are what people misspeak; a random common word
        (allow_common) only makes sense for an immediate correction."""
        candidates = []
        for i, w in enumerate(words):
            core = strip_word(w)
            if core in WEEKDAYS:
                candidates.append((3, i, rng.choice([d for d in WEEKDAYS if d != core])))
            elif core in MONTHS:
                candidates.append((3, i, rng.choice([m for m in MONTHS if m != core])))
            elif re.fullmatch(r"\d{1,4}", core):
                n = int(core)
                d = str(max(0, n + rng.choice([-3, -2, -1, 1, 2, 5, 10]))) if n < 1100 or n > 2099 else str(n + rng.choice([-2, -1, 1, 2]))
                candidates.append((3, i, d))
            elif i > 0 and re.fullmatch(r"[A-Z][a-z]{3,}", core) and self.proper:
                candidates.append((2, i, rng.choice(self.proper)))
            elif allow_common and re.fullmatch(r"[a-z]{4,}", core) and core not in STOPWORDS and self.content:
                candidates.append((1, i, rng.choice(self.content)))
        if not candidates:
            return None
        best = max(c[0] for c in candidates)
        # Prefer numbers, days and names, but not always.
        pool = [c for c in candidates if c[0] == best] if rng.random() < 0.7 else candidates
        _, i, d = rng.choice(pool)
        if strip_word(d) == strip_word(words[i]):
            return None
        return i, d

    @staticmethod
    def replace_core(word: str, new: str) -> str:
        core = strip_word(word)
        return word.replace(core, new, 1) if core else new

    def near_fix(self, words: list[str], rng: random.Random) -> bool:
        s = self.slot(words, rng, allow_common=rng.random() < 0.3)
        if not s:
            return False
        i, d = s
        cue = rng.choice(NEAR_CUES)
        sep = rng.choice([", ", " "])
        words[i] = self.replace_core(words[i], f"{d}{sep}{cue}{sep}{strip_word(words[i])}")
        return True

    def far_fix(self, sents: list[list[str]], rng: random.Random) -> bool:
        if len(sents) < 2:
            return False
        k = rng.randrange(len(sents) - 1)
        s = self.slot(sents[k], rng)
        if not s:
            return False
        i, d = s
        target = strip_word(sents[k][i])
        sents[k][i] = self.replace_core(sents[k][i], d)
        fix = rng.choice(FAR_TEMPLATES).format(t=target, d=d).split()
        at = rng.randint(k + 1, len(sents))  # after the next sentence or later
        sents.insert(at, fix)
        return True

    def scratch(self, sents: list[list[str]], rng: random.Random) -> bool:
        other = rng.choice(self.passages)["text"].split()
        if len(other) < 4:
            return False
        junk = [strip_word(w) or w for w in other[: rng.randint(3, min(10, len(other)))]]
        junk[0] = junk[0][:1].upper() + junk[0][1:]
        phrase = rng.choice(SCRATCH_PHRASES)
        if rng.random() < 0.5:
            junk = junk[:-1] + [junk[-1] + "."] + (phrase[:1].upper() + phrase[1:] + ".").split()
        else:
            junk = junk[:-1] + [junk[-1] + ","] + (phrase + ".").split()
        sents.insert(rng.randint(0, len(sents)), junk)
        return True

    @staticmethod
    def fillers(words: list[str], rng: random.Random) -> bool:
        n = max(1, min(4, len(words) // rng.randint(5, 9)))
        for _ in range(n):
            i = rng.randrange(len(words) + 1)
            filler = rng.choice(FILLERS)
            if rng.random() < 0.5:
                filler += ","
            if i == 0 and words and words[0][:1].isupper() and words[0] != "I" and not re.match(r"[A-Z]{2}|[A-Z][a-z]+[A-Z]", words[0]):
                words[0] = words[0][:1].lower() + words[0][1:]
            words.insert(i, filler if i else filler[:1].upper() + filler[1:])
        return True

    @staticmethod
    def stutter(words: list[str], rng: random.Random) -> bool:
        i = rng.randrange(len(words))
        w = strip_word(words[i])
        if not w or not w.isalpha():
            return False
        words.insert(i, (w[: rng.randint(1, min(3, len(w)))] + "-") if len(w) > 2 and rng.random() < 0.5 else w)
        return True

    @staticmethod
    def repeat(words: list[str], rng: random.Random) -> bool:
        if len(words) < 4:
            return False
        n = rng.randint(2, min(4, len(words) - 1))
        i = rng.randrange(len(words) - n)
        phrase = [strip_word(w) or w for w in words[i:i + n]]
        phrase[-1] += ","
        words[i:i] = phrase
        return True

    @staticmethod
    def false_start(words: list[str], rng: random.Random) -> bool:
        if len(words) < 6:
            return False
        k = rng.randint(1, 3)
        abandoned = [strip_word(w) or w for w in words[:k]] + [strip_word(w) for w in rng.sample(words[k + 1:], k=1)]
        abandoned = [w for w in abandoned if w]
        abandoned[-1] += rng.choice([",", ", uh,", ", I mean,", "... "]).rstrip()
        words[0:0] = abandoned
        if len(words) > len(abandoned):
            first = words[len(abandoned)]
            if first[:1].isupper() and first not in ("I",) and not re.match(r"[A-Z][a-z]+[A-Z]|[A-Z]{2}", first):
                words[len(abandoned)] = first[:1].lower() + first[1:]
        return True

    @staticmethod
    def split_name(words: list[str], rng: random.Random, vocab: list[str], fixes: list | None = None) -> bool:
        idx = [i for i, w in enumerate(words)
               if re.fullmatch(r"[A-Z][a-z]{5,}|[A-Z][a-z]+[A-Z][A-Za-z]+", strip_word(w)) and i > 0
               and strip_word(w) not in WEEKDAYS + MONTHS]
        if not idx:
            return False
        i = rng.choice(idx)
        term = strip_word(words[i])
        heard = respell(term, rng)
        if heard == term.lower():
            return False
        words[i] = words[i].replace(term, heard, 1)
        vocab.append(term)
        if fixes is not None:
            fixes.append([heard, term])
        return True

    def corrupt(self, passage: dict, index: int) -> dict | None:
        rng = random.Random(f"{self.seed}:{index}")
        text = passage["text"]
        sents = [s.split() for s in sentences(text)]
        if not sents:
            return None
        vocab: list[str] = []
        fixes: list[list[str]] = []
        applied: list[str] = []

        # The rarer, harder corruptions get boosted odds.
        menu = [("fillers", 0.45), ("stutter", 0.15), ("repeat", 0.15), ("false_start", 0.12), ("near_fix", 0.22),
                ("far_fix", 0.5 if len(sents) > 1 else 0), ("scratch", 0.1), ("split_name", 0.15),
                ("spoken_format", 0.12 if len(sents) > 1 else 0), ("spell_numbers", 0.9 if re.search(r"\d", text) else 0)]
        clean_only = rng.random() < 0.08
        for name, p in menu:
            if clean_only or rng.random() >= p:
                continue
            j = rng.randrange(len(sents))
            ok = False
            if name in ("fillers", "stutter", "repeat", "false_start"):
                ok = getattr(self, name)(sents[j], rng)
            elif name == "near_fix":
                ok = self.near_fix(sents[j], rng)
            elif name == "far_fix":
                ok = self.far_fix(sents, rng)
            elif name == "scratch":
                ok = self.scratch(sents, rng)
            elif name == "split_name":
                ok = self.split_name(sents[j], rng, vocab, fixes)
            elif name == "spell_numbers":
                changed = False
                for s in sents:
                    s[:], c = spell_numbers(s, rng)
                    changed |= c
                ok = changed
            elif name == "spoken_format":
                ok = True
            if ok:
                applied.append(name)

        output = text
        if "spoken_format" in applied:
            # Only between the original sentences, which still map 1:1 onto the output.
            if len(sents) != len(sentences(text)):
                applied.remove("spoken_format")
            else:
                command, joiner = rng.choice([("new paragraph", "\n\n"), ("new line", "\n")])
                pieces = sentences(text)
                cut = rng.randrange(1, len(pieces))
                output = " ".join(pieces[:cut]) + joiner + " ".join(pieces[cut:])
                sents[cut].insert(0, command)

        transcript = " ".join(" ".join(s) for s in sents)
        r = rng.random()
        if r < 0.35:
            transcript = re.sub(r"[^\w\s'$%-]|(?<!\w)-|-(?!\w)", "", transcript.lower())
            applied.append("no_punct")
        elif r < 0.55:
            transcript = transcript.lower()
            applied.append("lowercase")
        transcript = re.sub(r"\s+", " ", transcript).strip()

        if transcript.strip() == output.strip():
            return None
        return {"transcript": transcript, "output": output, "vocabulary": vocab, "fixes": fixes, "corruptions": applied,
                "category": category_of(applied)}


PRIORITY = [("far_fix", "backtrack_far"), ("near_fix", "backtrack_near"), ("scratch", "scratch"), ("split_name", "vocabulary"),
            ("false_start", "restarts"), ("repeat", "restarts"), ("spoken_format", "lists"), ("stutter", "restarts"),
            ("spell_numbers", "numbers"), ("fillers", "fillers")]


def category_of(applied: list[str]) -> str:
    for corruption, category in PRIORITY:
        if corruption in applied:
            return category
    return "already_clean"


def style_for(passage: dict, rng: random.Random) -> str:
    if passage["register"] == "instruction":
        return rng.choices(["casual", "prose", "code"], [5, 3, 2])[0]
    return rng.choices(["prose", "casual"], [8, 2])[0]


def run(passages: list[dict], count: int, seed: int) -> tuple[list[dict], collections.Counter]:
    corruptor = Corruptor(passages, seed)
    order = list(range(len(passages)))
    random.Random(seed).shuffle(order)
    out, dropped = [], collections.Counter()
    for index in order:
        if len(out) >= count:
            break
        passage = passages[index]
        pair = corruptor.corrupt(passage, index)
        if pair is None:
            dropped["unchanged"] += 1
            continue
        why = faithful(pair["transcript"], pair["output"], pair["vocabulary"], max_ratio=1.0)
        if why:
            dropped[why.split(":")[0]] += 1
            continue
        pair.update({"source": f"corrupt:{passage['source']}", "style": style_for(passage, random.Random(f"{seed}:s{index}"))})
        out.append(pair)
    return out, dropped


# --- Self-checks ------------------------------------------------------------

def selftest() -> None:
    assert say_int(0) == "zero" and say_int(42) == "forty two" and say_int(305) == "three hundred five"
    assert say_int(12000) == "twelve thousand" and say_int(1_250_000) == "one million two hundred fifty thousand"
    assert say_year(1994) == "nineteen ninety four" and say_year(2007) == "two thousand seven" and say_year(1905) == "nineteen oh five"
    assert say_year(2011) == "twenty eleven" and say_year(1800) == "eighteen hundred"
    assert say_ordinal(24) == "twenty fourth" and say_ordinal(1) == "first" and say_ordinal(30) == "thirtieth"
    r = random.Random(0)
    assert say_number_token("$12", r) == "twelve dollars" and say_number_token("3.5", r) == "three point five"
    assert say_number_token("40%", r) == "forty percent" and say_number_token("1990s", r) == "nineteen nineties"
    assert say_number_token("1,200", r) == "one thousand two hundred" and say_number_token("abc", r) is None
    assert spell_numbers(["at", "3pm"], r)[0] == ["at", "3pm"]
    assert spell_numbers(["in", "1994,", "about"], r)[0] == ["in", "nineteen ninety four,", "about"]
    assert respell("Valkyria", random.Random(1)) != "Valkyria"

    passages = [
        {"source": "t", "register": "prose", "text": "The meeting moved to Tuesday at 3 in the main hall. Bring the slides and the budget. Maria will present the 2019 results."},
        {"source": "t", "register": "instruction", "text": "Can you write a short poem about the ocean for my sister?"},
        {"source": "t", "register": "prose", "text": "Sega released Valkyria Chronicles in Japan in 2011. It sold 102,000 copies in its first week."},
    ] * 40
    a, _ = run(passages, 100, seed=5)
    b, _ = run(passages, 100, seed=5)
    assert a == b, "same seed must give the same pairs"
    c, _ = run(passages, 100, seed=6)
    assert a != c, "different seeds should differ"
    for p in a:
        assert faithful(p["transcript"], p["output"], p["vocabulary"], max_ratio=1.0) is None, p
        assert p["category"] == category_of(p["corruptions"])

    # Each corruption does what it says on a fixed sentence.
    co = Corruptor(passages, 0)
    base = "We should meet on Tuesday with Marisol to review the budget.".split()
    for seed in range(20):
        w = list(base)
        assert co.near_fix(w, random.Random(seed))
        joined = " ".join(w)
        assert any(c in joined for c in NEAR_CUES) and len(w) == len(base)
    sents = [s.split() for s in sentences(passages[0]["text"])]
    assert co.far_fix(sents, random.Random(3)) and len(sents) == 4
    w = list(base)
    vocab: list[str] = []
    assert Corruptor.split_name(w, random.Random(2), vocab) and vocab == ["Marisol"]
    w = list(base)
    assert Corruptor.repeat(w, random.Random(4)) and len(w) > len(base)

    seen = collections.Counter(c for p in run(passages * 10, 1000, seed=1)[0] for c in p["corruptions"])
    for name in ("fillers", "stutter", "repeat", "false_start", "near_fix", "far_fix", "scratch", "split_name",
                 "spoken_format", "spell_numbers", "no_punct", "lowercase"):
        assert seen[name] > 0, f"{name} never applied"
    print("selftest passed:", dict(seen))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("passages", nargs="?", type=Path)
    parser.add_argument("--count", type=int, default=10000)
    parser.add_argument("--out", type=Path, default=Path("data/corrupt/pairs.jsonl"))
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--show", type=int, default=0, help="print this many examples")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if not args.passages:
        parser.error("passages file required")

    passages = [json.loads(l) for l in args.passages.read_text().splitlines() if l.strip()]
    pairs, dropped = run(passages, args.count, args.seed)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w") as f:
        for p in pairs:
            f.write(json.dumps(p) + "\n")
    for p in pairs[: args.show]:
        print(json.dumps(p, indent=1))
    cats = collections.Counter(p["category"] for p in pairs)
    print(f"wrote {len(pairs)} pairs to {args.out}; categories {dict(cats.most_common())}; dropped {dict(dropped)}")


if __name__ == "__main__":
    main()
