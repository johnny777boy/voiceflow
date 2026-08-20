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

def _numbers_to_digits(words):
    """Fold spoken numbers into digits so FORMATTING is not scored as mishearing.

    "the island is fifty seven inches" and "the island is 57 inches" are the same
    hearing; only one of them is the app's chosen output format. Without this,
    every number in the reference costs 1-2 word errors and inflates WER —
    exactly the noise that swamps the ~1 point the model question turns on.
    Applied identically to reference and hypothesis, so it can never favour one.
    """
    out, i = [], 0
    while i < len(words):
        w = words[i]
        if w in _TENS:
            value = _TENS[w]
            if i + 1 < len(words) and words[i + 1] in _UNITS and 1 <= _UNITS[words[i + 1]] <= 9:
                value += _UNITS[words[i + 1]]; i += 1
            out.append(str(value))
        elif w in _UNITS:
            # "one hundred" style compounds are left alone: they are rare in his
            # speech and guessing at them would introduce errors of its own.
            out.append(str(_UNITS[w]))
        else:
            out.append(w)
        i += 1
    return out

def normalize(text):
    text = text.lower()
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
    with open(path) as f:
        return [line.rstrip("\n") for line in f if line.strip() != ""]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference"); ap.add_argument("hyp_a"); ap.add_argument("hyp_b")
    ap.add_argument("--labels", default="A,B")
    ap.add_argument("--entities", help="file of one term per line (may be multi-word)")
    ap.add_argument("--resamples", type=int, default=10000)
    a = ap.parse_args()

    ref, ha, hb = load(a.reference), load(a.hyp_a), load(a.hyp_b)
    n = min(len(ref), len(ha), len(hb))
    if not (len(ref) == len(ha) == len(hb)):
        print(f"WARNING: line counts differ (ref {len(ref)}, A {len(ha)}, B {len(hb)}) — "
              f"scoring the first {n}. Pairing by line is the whole design, so an "
              f"unequal count usually means a missing dictation, not a tie.\n")
    ref, ha, hb = ref[:n], ha[:n], hb[:n]
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

if __name__ == "__main__":
    main()
