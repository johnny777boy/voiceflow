#!/usr/bin/env python3
"""Audit what VoiceFlow actually did to your words.

Reads the live history database and answers, from data, the question that keeps
coming back as "it's still not accurate":

  - did the ENGINE hear you right?            (raw transcript, per engine)
  - did CLEANUP propose a fix?                (cleanupProposed)
  - did the GUARD throw that fix away, why?   (cleanupDecision / cleanupRejectReason)
  - what does the delivered text READ like?   (filler density, run-ons, caps)

Usage
  Scripts/audit_cleanup.py                 summary of the last 200 dictations
  Scripts/audit_cleanup.py --detail        every dictation: said / proposed / delivered
  Scripts/audit_cleanup.py --rejected      only the ones the guard reverted
  Scripts/audit_cleanup.py --since 2026-08-19
  Scripts/audit_cleanup.py --limit 50
"""
import argparse, os, re, sqlite3, sys
from collections import Counter

DB = os.path.expanduser("~/Library/Application Support/VoiceFlow/history.sqlite")

# Discourse markers are NOT deleted by the app on purpose (they carry meaning in
# his work: "dig a new well", "turn right"). They are counted here only to
# describe how the delivered text READS.
FILLERS = ["like", "i mean", "you know", "actually", "basically", "obviously",
           "kind of", "sort of", "literally", "so"]

def bar(n, total, width=28):
    if not total: return ""
    filled = int(round(width * n / total))
    return "█" * filled + "·" * (width - filled)

def columns(con):
    return {r[1] for r in con.execute("PRAGMA table_info(transcripts)")}

def fetch(args):
    if not os.path.exists(DB):
        sys.exit(f"no history database at {DB}")
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    have = columns(con)
    audit_ready = {"cleanupDecision", "cleanupProposed", "cleanupRejectReason"} <= have
    cols = ["createdAt", "rawText", "cleanText", "engineUsed", "appName",
            "cleanupSeconds", "transcribeSeconds", "editedAfterInsert"]
    cols += (["cleanupProposed", "cleanupDecision", "cleanupRejectReason"]
             if audit_ready else [])
    sql = f"SELECT {','.join(cols)} FROM transcripts"
    where, params = [], []
    if args.since:
        where.append("createdAt >= strftime('%s', ?, 'utc')")
        params.append(args.since)
    if where: sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY createdAt DESC LIMIT ?"
    params.append(args.limit)
    rows = [dict(zip(cols, r)) for r in con.execute(sql, params)]
    return rows, audit_ready

def sentences(text):
    return [s for s in re.split(r"(?<=[.!?])\s+", text.strip()) if s]

def report(rows, audit_ready, args):
    n = len(rows)
    if not n: sys.exit("no dictations in range")
    print(f"\n\033[1mVoiceFlow cleanup audit\033[0m — {n} dictations "
          f"({rows[-1]['createdAt'] and __import__('datetime').datetime.fromtimestamp(rows[-1]['createdAt']).strftime('%Y-%m-%d %H:%M')}"
          f" → {__import__('datetime').datetime.fromtimestamp(rows[0]['createdAt']).strftime('%Y-%m-%d %H:%M')})\n")

    # 1. Engine — did it HEAR you.
    eng = Counter(r["engineUsed"] or "(unrecorded)" for r in rows)
    print("\033[1m1. Which engine heard you\033[0m")
    for name, c in eng.most_common():
        print(f"   {name:<12} {c:>4}  {bar(c, n)}")
    if eng.get("apple"):
        print("   \033[33mnote:\033[0m every 'apple' row is a dictation Whisper did NOT serve.")
    print()

    # 2. Cleanup — did it POLISH you, and was the polish kept.
    print("\033[1m2. What cleanup did with it\033[0m")
    if not audit_ready:
        untouched = sum(1 for r in rows if r["rawText"] == r["cleanText"])
        print(f"   \033[33mNo audit data in this database yet.\033[0m")
        print(f"   {untouched}/{n} delivered text identical to the raw transcript — but with")
        print( "   these columns missing there is no way to tell 'the model had nothing")
        print( "   to fix' from 'the guard silently reverted the fix'. Dictate on the")
        print( "   build that records it, then run this again.\n")
    else:
        dec = Counter(r["cleanupDecision"] or "(unrecorded)" for r in rows)
        for name, c in dec.most_common():
            colour = {"rejected": "\033[31m", "partial": "\033[33m",
                      "accepted": "\033[32m"}.get(name, "")
            print(f"   {colour}{name:<12}\033[0m {c:>4}  {bar(c, n)}")
        reasons = Counter(r["cleanupRejectReason"] for r in rows if r["cleanupRejectReason"])
        if reasons:
            print("\n   \033[1mWhy the guard refused\033[0m (this is the accuracy argument, settled)")
            for name, c in reasons.most_common(12):
                print(f"   {c:>4}×  {name}")
        print()

    # 3. How the delivered text READS.
    print("\033[1m3. How the delivered text reads\033[0m")
    total_words = sum(len(r["cleanText"].split()) for r in rows)
    fill = Counter()
    for r in rows:
        low = " " + r["cleanText"].lower() + " "
        for f in FILLERS:
            fill[f] += len(re.findall(rf"(?<![\w']){re.escape(f)}(?![\w'])", low))
    filler_total = sum(fill.values())
    longest = max(rows, key=lambda r: max((len(s.split()) for s in sentences(r["cleanText"])), default=0))
    long_sent = max((len(s.split()) for s in sentences(longest["cleanText"])), default=0)
    runons = sum(1 for r in rows for s in sentences(r["cleanText"]) if len(s.split()) > 40)
    print(f"   words delivered      {total_words}")
    print(f"   discourse markers    {filler_total}  ({100*filler_total/max(total_words,1):.1f}% of words)"
          f"   {', '.join(f'{w}×{c}' for w, c in fill.most_common(5) if c)}")
    print(f"   longest sentence     {long_sent} words")
    print(f"   sentences >40 words  {runons}")
    edited = sum(1 for r in rows if r["editedAfterInsert"])
    print(f"   you edited after     {edited}/{n}  ({100*edited/n:.0f}%)")
    print()

    # 4. Per-dictation detail.
    if args.detail or args.rejected:
        print("\033[1m4. Dictation by dictation\033[0m\n")
        for r in rows:
            if args.rejected and (r.get("cleanupDecision") not in ("rejected", "partial")):
                continue
            when = __import__('datetime').datetime.fromtimestamp(r["createdAt"]).strftime("%m-%d %H:%M")
            print(f"\033[1m{when}\033[0m  {r['engineUsed'] or '?'}  {r['appName'] or ''}"
                  f"  [{r.get('cleanupDecision') or 'no audit'}]")
            print(f"   said      {r['rawText']}")
            if r.get("cleanupProposed") and r["cleanupProposed"] != r["rawText"]:
                print(f"   proposed  {r['cleanupProposed']}")
            if r["cleanText"] != r["rawText"]:
                print(f"   delivered {r['cleanText']}")
            else:
                print(f"   delivered \033[2m(unchanged)\033[0m")
            if r.get("cleanupRejectReason"):
                print(f"   \033[31mrefused   {r['cleanupRejectReason']}\033[0m")
            print()

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--detail", action="store_true", help="show every dictation")
    ap.add_argument("--rejected", action="store_true", help="show only guard-reverted dictations")
    ap.add_argument("--since", help="YYYY-MM-DD")
    ap.add_argument("--limit", type=int, default=200)
    args = ap.parse_args()
    rows, audit_ready = fetch(args)
    report(rows, audit_ready, args)
