#!/usr/bin/env python3
"""
Word Error Rate (WER) scorer — the objective way to prove VoiceFlow is as accurate
as Wispr. WER is the standard speech-recognition metric: the percent of words wrong
(substitutions + deletions + insertions) versus a known reference.

Usage:
    python3 Scripts/wer.py reference.txt hypothesis.txt
    # or pipe/paste:
    python3 Scripts/wer.py --ref "the exact words you read" --hyp "what the app wrote"

Compare two apps: run it once with VoiceFlow's output as the hypothesis, once with
Wispr's. Lower WER = more accurate. If the two numbers are within ~1-2 points, the
apps are equivalent.
"""
import sys, re, argparse

def normalize(text):
    # Lowercase, strip punctuation, collapse whitespace — so we score WORDS, not
    # formatting (commas/periods are a separate concern from "did it hear the word").
    text = text.lower()
    text = re.sub(r"[^\w\s']", " ", text)      # keep apostrophes (don't, it's)
    text = re.sub(r"\s+", " ", text).strip()
    return text.split()

def wer(ref_words, hyp_words):
    # Levenshtein distance over words (dynamic programming).
    n, m = len(ref_words), len(hyp_words)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if ref_words[i - 1] == hyp_words[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1,        # deletion
                          d[i][j - 1] + 1,        # insertion
                          d[i - 1][j - 1] + cost) # substitution/match
    # Backtrack to count S/D/I and build an aligned diff.
    i, j, S, D, I, diff = n, m, 0, 0, 0, []
    while i > 0 or j > 0:
        if i > 0 and j > 0 and ref_words[i-1] == hyp_words[j-1] and d[i][j] == d[i-1][j-1]:
            diff.append(ref_words[i-1]); i -= 1; j -= 1
        elif i > 0 and j > 0 and d[i][j] == d[i-1][j-1] + 1:
            diff.append(f"[{ref_words[i-1]}→{hyp_words[j-1]}]"); S += 1; i -= 1; j -= 1
        elif j > 0 and d[i][j] == d[i][j-1] + 1:
            diff.append(f"[+{hyp_words[j-1]}]"); I += 1; j -= 1
        else:
            diff.append(f"[-{ref_words[i-1]}]"); D += 1; i -= 1
    diff.reverse()
    errors = S + D + I
    rate = 100.0 * errors / max(1, n)
    return rate, S, D, I, n, " ".join(diff)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref_file", nargs="?"); ap.add_argument("hyp_file", nargs="?")
    ap.add_argument("--ref"); ap.add_argument("--hyp")
    a = ap.parse_args()
    ref = a.ref if a.ref else open(a.ref_file).read()
    hyp = a.hyp if a.hyp else open(a.hyp_file).read()
    r, s, dele, ins, n, diff = wer(normalize(ref), normalize(hyp))
    print(f"\nWORD ERROR RATE: {r:.1f}%   ({s} substituted, {dele} deleted, {ins} inserted, of {n} words)")
    print(f"Accuracy: {100 - r:.1f}%\n")
    print("Aligned diff (→ substitution, +extra, -missing):")
    print(" ", diff, "\n")
    if r <= 5:   print("Verdict: PROFESSIONAL / Whisper-level (≤5% WER).")
    elif r <= 10:print("Verdict: Good — a few misses. Compare to Wispr's number on the same script.")
    else:        print("Verdict: High error rate — investigate (mic, locale, or clipping).")

if __name__ == "__main__":
    main()
