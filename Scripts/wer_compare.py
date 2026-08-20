#!/usr/bin/env python3
"""Paired A/B of two transcription runs over the SAME audio.

Why this exists: the old protocol was "read the script, switch model, read it
again" and score each. That measures the READING as much as the model, and with
a 136-word reference a single error moves WER by 0.74 — far larger than the
~1 point the model question turns on. So: decode identical audio twice
(Scripts/VoiceFlowBench does that), then score the two hypothesis files against
one reference HERE, paired per utterance, with a bootstrap that says whether the
difference is real or noise.

    Scripts/wer_compare.py ref.txt hypA.txt hypB.txt [--entities docs/wer-entities.txt]

Line N of every file must be the same utterance. Reports overall WER for each
run, the paired difference with a 95 percent confidence interval and p-value
(paired bootstrap over utterances, the standard ASR significance test), and —
separately — entity WER over the words that actually matter to the user
(product names, jargon). Biasing typically moves entity WER a lot and overall
WER a little, so overall-only scoring would call a real win a placebo.
"""
import argparse, random, re, sys

_UNITS = {"zero":0,"one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,
          "eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12,"thirteen":13,
          "fourteen":14,"fifteen":15,"sixteen":16,"seventeen":17,"eighteen":18,
          "nineteen":19}
_TENS = {"twenty":20,"thirty":30,"forty":40,"fifty":50,"sixty":60,"seventy":70,
         "eighty":80,"ninety":90}
_SCALE = {"hundred":100, "thousand":1000, "million":1000000}
_ORDINALS = {"first":"1","second":"2","third":"3","fourth":"4","fifth":"5",
             "sixth":"6","seventh":"7","eighth":"8","ninth":"9","tenth":"10",
             "eleventh":"11","twelfth":"12","thirteenth":"13","fourteenth":"14",
             "fifteenth":"15","sixteenth":"16","seventeenth":"17",
             "eighteenth":"18","nineteenth":"19","twentieth":"20","thirtieth":"30"}
# Whisper contracts; a read script does not. Scoring that as a mishearing was
# worth 3.8 WER points on this reference — more than three times the acoustic
# effect the whole experiment is trying to detect, and NOT symmetric: a
# 4-layer distilled decoder and a 32-layer one contract at different rates, so
# it is a model-correlated confound sitting inside a "same audio" experiment.
_CONTRACTIONS = {
    "won't":"will not", "can't":"cannot", "cant":"cannot", "n't":" not",
    "isn't":"is not", "aren't":"are not", "wasn't":"was not",
    "weren't":"were not", "don't":"do not", "doesn't":"does not",
    "didn't":"did not", "haven't":"have not", "hasn't":"has not",
    "hadn't":"had not", "wouldn't":"would not", "shouldn't":"should not",
    "couldn't":"could not", "we're":"we are", "they're":"they are",
    "you're":"you are", "i'm":"i am", "he's":"he is", "she's":"she is",
    "it's":"it is", "that's":"that is", "there's":"there is",
    "what's":"what is", "let's":"let us", "i'll":"i will", "we'll":"we will",
    "you'll":"you will", "they'll":"they will", "he'll":"he will",
    "she'll":"she will", "i've":"i have", "we've":"we have",
    "you've":"you have", "they've":"they have", "i'd":"i would",
    "we'd":"we would", "half":"1/2",
}

def _expand_contractions(text):
    for short, long in _CONTRACTIONS.items():
        text = re.sub(rf"(?<![\w']){re.escape(short)}(?![\w'])", long, text)
    return text

def _numbers_to_digits(words):
    """Fold spoken numbers, ordinals and scale words into digits.

    FORMATTING IS NOT HEARING. "fifty seven"/"57", "twelve hundred"/"1200",
    "the fifteenth"/"the 15th", "four oh three"/"403" are the same hearing;
    only one is the app's output style. Applied identically to reference and
    hypothesis, so it can never favour one — but leaving it out let 3.8 WER
    points of pure style dominate a 1.1-point acoustic signal.
    """
    out, i = [], 0
    while i < len(words):
        w = words[i]
        if w in _ORDINALS:
            out.append(_ORDINALS[w]); i += 1; continue
        # "<n>th" spoken as a digit ordinal, e.g. "15th" -> "15"
        m = re.fullmatch(r"(\d+)(st|nd|rd|th)", w)
        if m:
            out.append(m.group(1)); i += 1; continue
        value, consumed = None, 0
        if w in _TENS:
            value = _TENS[w]; consumed = 1
            if i + 1 < len(words) and words[i + 1] in _UNITS and 1 <= _UNITS[words[i + 1]] <= 9:
                value += _UNITS[words[i + 1]]; consumed = 2
        elif w in _UNITS:
            value = _UNITS[w]; consumed = 1
        elif w.isdigit():
            value = int(w); consumed = 1
        if value is not None:
            # Scale words: "twelve hundred" -> 1200, "ninety four thousand" -> 94000.
            if i + consumed < len(words) and words[i + consumed] in _SCALE:
                value *= _SCALE[words[i + consumed]]
                consumed += 1
            out.append(str(value)); i += consumed; continue
        # "four oh three" -> "403": digits joined by spoken zeros.
        out.append(w); i += 1
    # Whether currency is spoken ("twelve hundred dollars") or symbolised
    # ("$1,200") is formatting; the NUMBER is the content. Dropping the currency
    # word after a digit makes the two forms comparable in both directions. The
    # cost is that a genuinely missed "dollars" goes unscored — an acceptable
    # trade for removing a model-correlated confound, and stated here so nobody
    # rediscovers it as a bug.
    folded = []
    for token in out:
        if token in ("dollars", "dollar", "bucks") and folded and folded[-1].isdigit():
            continue
        folded.append(token)
    out = folded

    # Second pass: join a run of bare digits that spell one number ("4 oh 3").
    joined, i = [], 0
    while i < len(joined_src := out):
        if (joined_src[i].isdigit() and i + 2 < len(joined_src)
                and joined_src[i + 1] in ("oh", "o", "0")
                and joined_src[i + 2].isdigit()):
            joined.append(joined_src[i] + "0" + joined_src[i + 2]); i += 3
        else:
            joined.append(joined_src[i]); i += 1
    return joined

def normalize(text):
    text = text.lower()
    text = text.replace("\u2019", "'")              # curly apostrophe
    text = re.sub(r"(\d),(\d)", r"\1\2", text)       # 1,200 -> 1200
    text = re.sub(r"\$\s*([\d.]+)", r"\1", text)          # $1,200 -> 1200
    text = re.sub(r"([\d.]+)\s*%", r"\1 percent", text)
    text = _expand_contractions(text)
    text = re.sub(r"[^\w\s']", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return _numbers_to_digits(text.split())

def edits(ref, hyp):
    """(substitutions+deletions+insertions, len(ref)) via word-level Levenshtein."""
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
    return d[n][m], n

def entity_counts(ref, hyp, entities):
    """How many entity tokens in the reference survived into the hypothesis.

    Counted as a multiset so "Codex ... Codex" needs both. Position-free on
    purpose: we are asking whether the WORD was recognised, not where it landed.
    """
    from collections import Counter
    want = Counter(w for w in ref if w in entities)
    got = Counter(w for w in hyp if w in entities)
    total = sum(want.values())
    hit = sum(min(c, got[w]) for w, c in want.items())
    return hit, total

def load(path):
    """Every line, blanks included.

    The bench writes an EMPTY line for a decode that produced nothing, precisely
    so line N keeps meaning utterance N. Dropping blanks here would shift every
    later pair by one and score ~100% WER on all of them — then report, with a
    tight confidence interval, that the other model is dramatically better. That
    is the confident-wrong-answer this whole file exists to prevent. A blank
    hypothesis is a real scoring unit (all deletions), not an absent one.
    """
    with open(path) as f:
        return [line.rstrip("\n") for line in f]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference"); ap.add_argument("hyp_a"); ap.add_argument("hyp_b")
    ap.add_argument("--labels", default="A,B")
    ap.add_argument("--entities", help="file of one term per line (may be multi-word)")
    ap.add_argument("--resamples", type=int, default=10000)
    a = ap.parse_args()

    ref, ha, hb = load(a.reference), load(a.hyp_a), load(a.hyp_b)
    # Trailing blank lines from the file's final newline are not utterances.
    while ref and not ref[-1].strip(): ref.pop()
    if len(ref) != len(ha) or len(ref) != len(hb):
        sys.exit(
            f"REFUSING TO SCORE: line counts differ (reference {len(ref)}, "
            f"{a.hyp_a} {len(ha)}, {a.hyp_b} {len(hb)}).\n"
            f"Pairing line N with utterance N IS the design — scoring a mismatched "
            f"set silently compares different sentences and produces a confident "
            f"wrong answer. Re-record the session, or trim the files so every line "
            f"corresponds.")
    n = len(ref)
    if n == 0:
        sys.exit("REFUSING TO SCORE: nothing to compare (empty corpus).")
    label_a, label_b = (a.labels.split(",") + ["A", "B"])[:2]

    entities = set()
    if a.entities:
        for line in load(a.entities):
            entities.update(normalize(line))

    per = []   # (errA, errB, words) per utterance — the paired unit
    ent = [0, 0, 0]
    for r, x, y in zip(ref, ha, hb):
        rw, xw, yw = normalize(r), normalize(x), normalize(y)
        ea, words = edits(rw, xw)
        eb, _ = edits(rw, yw)
        per.append((ea, eb, words))
        if entities:
            hit_a, tot = entity_counts(rw, xw, entities)
            hit_b, _ = entity_counts(rw, yw, entities)
            ent[0] += hit_a; ent[1] += hit_b; ent[2] += tot

    words = sum(p[2] for p in per)
    wer_a = sum(p[0] for p in per) / max(words, 1) * 100
    wer_b = sum(p[1] for p in per) / max(words, 1) * 100

    print(f"utterances {n}   reference words {words}\n")
    print(f"  {label_a:<28} WER {wer_a:6.2f}%")
    print(f"  {label_b:<28} WER {wer_b:6.2f}%")
    print(f"  {'difference':<28}     {wer_b - wer_a:+6.2f} points "
          f"({'B better' if wer_b < wer_a else 'A better' if wer_a < wer_b else 'tie'})\n")

    # Paired bootstrap over utterances: resample WHOLE utterances with
    # replacement, recompute the difference, and read the spread. Pairing is what
    # buys the power — identical audio means only the discordant words vary.
    rng = random.Random(20260819)
    diffs = []
    for _ in range(a.resamples):
        sample = [per[rng.randrange(n)] for _ in range(n)]
        w = sum(p[2] for p in sample) or 1
        diffs.append((sum(p[1] for p in sample) - sum(p[0] for p in sample)) / w * 100)
    diffs.sort()
    lo, hi = diffs[int(0.025 * len(diffs))], diffs[int(0.975 * len(diffs))]
    # THE HONEST HEADLINE. An underpowered test reports "not significant" for a
    # real effect most of the time, and this project's plan pre-authorised
    # reading that as "the claim is falsified for his voice" — which converts a
    # null result into a positive claim. So state up front what this sample can
    # actually see. Half the CI width is the smallest difference that could
    # clear zero here.
    floor = (hi - lo) / 2
    print(f"  RESOLVING POWER: this sample can only detect differences larger")
    print(f"  than about {floor:.1f} points. Anything smaller will read as")
    print(f"  \"not significant\" EVEN IF IT IS REAL — that is not evidence of a tie.")
    if floor > 1.0:
        print(f"  The model question turns on ~1.1 points, so {n} utterances /"
              f" {words} words is")
        print(f"  NOT ENOUGH to settle it. Read more (aim for ~250 utterances /"
              f" ~3000 words),")
        print(f"  or decide on the published prior instead of this run.")
    print()
    # Two-sided p: how often the resampled difference lands on the other side of 0.
    worse = sum(1 for d in diffs if d >= 0) if wer_b < wer_a else sum(1 for d in diffs if d <= 0)
    p = 2 * worse / len(diffs)
    print(f"  95% CI of the difference  [{lo:+.2f}, {hi:+.2f}] points   p ≈ {min(p, 1.0):.3f}")
    if lo <= 0 <= hi:
        print(f"  → NOT significant. The interval spans zero: this sample cannot tell\n"
              f"    {label_a} and {label_b} apart. More utterances, or the difference is noise.")
    else:
        better = label_b if wer_b < wer_a else label_a
        print(f"  → {better} is genuinely better on this voice (interval excludes zero).")

    if entities:
        ea = ent[0] / max(ent[2], 1) * 100
        eb = ent[1] / max(ent[2], 1) * 100
        print(f"\n  entity recall ({ent[2]} entity words: names, products, jargon)")
        print(f"    {label_a:<26} {ea:6.1f}%   ({ent[0]}/{ent[2]})")
        print(f"    {label_b:<26} {eb:6.1f}%   ({ent[1]}/{ent[2]})")
        print(f"    This is where context biasing shows up; overall WER barely moves.")

# Perfect hearing, ordinary model formatting. Every pair MUST score zero — if any
# of them costs a word error, the scorer is measuring output style instead of
# whether the engine heard him, and style differs BY MODEL (a 4-layer decoder
# contracts less than a 32-layer one), so it lands as a confound three times the
# size of the effect being measured.
SELF_TEST_PAIRS = [
    ("I will not send it until you confirm", "I won't send it until you confirm."),
    ("We are using Next.js and PostgreSQL", "We're using Next.js and PostgreSQL."),
    ("we are twelve hundred dollars over budget", "We're $1,200 over budget."),
    ("let the client know it arrives on the fifteenth", "Let the client know it arrives on the 15th."),
    ("the API returns a four oh three", "The API returns a 403."),
    ("the bid came in at ninety four thousand", "The bid came in at $94,000."),
    ("three more sheets of half inch drywall", "Three more sheets of 1/2 inch drywall."),
    ("the island is fifty seven by thirty five inches", "The island is 57 by 35 inches."),
    ("do not order the flooring", "Don't order the flooring."),
    ("make sure the HVAC return is not blocked", "Make sure the HVAC return isn't blocked."),
    ("he cannot rough in until the plumber is done", "He can't rough in until the plumber is done."),
    ("so they are remaking the two casements", "So they're remaking the two casements."),
]

def self_test():
    failures = []
    for said, formatted in SELF_TEST_PAIRS:
        e, n = edits(normalize(said), normalize(formatted))
        if e: failures.append((said, formatted, e, normalize(said), normalize(formatted)))
    if failures:
        print("SCORER SELF-TEST FAILED — it is measuring formatting, not hearing:\n")
        for said, formatted, e, a, b in failures:
            print(f"  {e} error(s)\n    said : {said}\n    got  : {formatted}\n"
                  f"    ref norm: {a}\n    hyp norm: {b}\n")
        return 1
    print(f"scorer self-test: {len(SELF_TEST_PAIRS)} formatting pairs all score 0.00 WER")
    return 0

if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    main()
