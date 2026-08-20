#!/usr/bin/env python3
"""Show only the sentences where the two models disagree, and tally the verdict.

A forced-choice preference test. No reference transcript exists for spontaneous
speech, and writing one by hand is the very effort this avoids — but we do not
need one: for each disagreement the speaker knows what he said, so he can say
which transcript is right. Agreements carry no information about which model is
better, so they are never shown.
"""
import sys, os, re, random

B,G,Y,R,D,O = "\033[1m","\033[32m","\033[33m","\033[31m","\033[2m","\033[0m"

def load(p):
    with open(p) as f: return [l.rstrip("\n") for l in f]

def norm(t):
    return re.sub(r"\s+"," ", re.sub(r"[^\w\s']"," ", t.lower())).strip()

def main():
    small, big = load(sys.argv[1]), load(sys.argv[2])
    n = min(len(small), len(big))
    pairs = [(i, small[i], big[i]) for i in range(n) if norm(small[i]) != norm(big[i])]
    agree = n - len(pairs)
    print(f"\n{B}{n} dictations. They agreed on {agree}, disagreed on {len(pairs)}.{O}")
    if not pairs:
        print("No disagreements — on your speech these two models are equivalent.")
        print("Keep the small one: it is 2-3x faster for the same result.\n"); return
    print(f"{D}Only the disagreements matter. For each, say which is right.{O}")
    print(f"{D}1 = first, 2 = second, s = skip (both wrong / can't tell), q = stop{O}\n")
    # Randomise which side is shown first, so a habit of picking "1" cannot
    # decide the outcome.
    rng = random.Random(20260819)
    wins = {"small":0, "big":0, "skip":0}
    for k, (i, a, b) in enumerate(pairs, 1):
        flip = rng.random() < 0.5
        first, second = (b, a) if flip else (a, b)
        print(f"{B}[{k}/{len(pairs)}]{O}")
        print(f"  {B}1.{O} {first}")
        print(f"  {B}2.{O} {second}")
        try: ans = input(f"  which is right? [1/2/s/q] ").strip().lower()
        except (EOFError, KeyboardInterrupt): print(); break
        print()
        if ans == "q": break
        if ans == "1": wins["big" if flip else "small"] += 1
        elif ans == "2": wins["small" if flip else "big"] += 1
        else: wins["skip"] += 1
    judged = wins["small"] + wins["big"]
    print(f"{B}{'='*56}{O}")
    if judged == 0:
        print("Nothing judged — no verdict.\n"); return
    print(f"{B}Result on your own voice{O}\n")
    print(f"  small model (current)  won {wins['small']:>3}  of {judged}")
    print(f"  big model              won {wins['big']:>3}  of {judged}")
    if wins["skip"]: print(f"  {D}skipped{' '*16}{wins['skip']}{O}")
    lead = wins["big"] - wins["small"]
    # Sign test: how surprising is this lead if the models were equally good?
    from math import comb
    p = sum(comb(judged,k) for k in range(max(wins['small'],wins['big']), judged+1)) / (2**judged) * 2
    print()
    if lead > 0 and p < 0.05:
        print(f"  {G}{B}The big model is genuinely better on your voice.{O} (p≈{p:.3f})")
        print("  Worth the extra ~1 second per dictation. Tell Claude to switch it on.")
    elif lead < 0 and p < 0.05:
        print(f"  {G}{B}The small model is better.{O} (p≈{p:.3f}) Keep what you have.")
    else:
        print(f"  {Y}Too close to call from {judged} judgements (p≈{p:.3f}).{O}")
        need = max(0, 30 - judged)
        print(f"  Keep dictating and run this again{f' — about {need} more disagreements' if need else ''}.")
    print()

if __name__ == "__main__": main()
