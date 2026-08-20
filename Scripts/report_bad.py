#!/usr/bin/env python3
"""Report a dictation that came out wrong — and find out WHICH STAGE broke it.

"Extra words / missing words / wrong words" have three different causes and
three different fixes, and guessing which one you hit is what makes the accuracy
argument go in circles. This pairs what you ACTUALLY said with what the app
recorded at each stage and assigns the blame mechanically.

  Scripts/report_bad.py                       fix the most recent dictation
  Scripts/report_bad.py --pick                choose from the last 10
  Scripts/report_bad.py -m "what I said"      non-interactive

Every report is appended to docs/bad-dictations.jsonl, which is both a growing
regression corpus and real WER data on your own voice.
"""
import argparse, datetime, difflib, json, os, sqlite3, sys

DB = os.path.expanduser("~/Library/Application Support/VoiceFlow/history.sqlite")
# NOT in the repo. These lines contain the verbatim text of real dictations —
# client names, addresses, prices, change orders. docs/ is tracked and the merge
# ritual pushes the branch to GitHub, so one `git add -A` would publish them.
# They live with the rest of the local-only data instead.
CORPUS = os.path.expanduser("~/Library/Application Support/VoiceFlow/bad-dictations.jsonl")
BOLD, RED, GRN, YEL, DIM, OFF = "\033[1m", "\033[31m", "\033[32m", "\033[33m", "\033[2m", "\033[0m"

def rows(limit):
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    have = {r[1] for r in con.execute("PRAGMA table_info(transcripts)")}
    extra = ["cleanupProposed", "cleanupDecision", "cleanupRejectReason"] if \
        {"cleanupProposed", "cleanupDecision", "cleanupRejectReason"} <= have else []
    cols = ["id", "createdAt", "rawText", "cleanText", "engineUsed", "appName"] + extra
    q = f"SELECT {','.join(cols)} FROM transcripts ORDER BY createdAt DESC LIMIT ?"
    return [dict(zip(cols, r)) for r in con.execute(q, (limit,))]

def words(t): return (t or "").lower().replace(",", " ").replace(".", " ").split()

def diff(a, b):
    """Word-level differences, as (added, removed) lists."""
    sm = difflib.SequenceMatcher(a=words(a), b=words(b))
    added, removed = [], []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag in ("replace", "delete"): removed += words(a)[i1:i2]
        if tag in ("replace", "insert"): added += words(b)[j1:j2]
    return added, removed

def show(r, meant):
    when = datetime.datetime.fromtimestamp(r["createdAt"]).strftime("%b %d %H:%M")
    print(f"\n{BOLD}Dictation {when}{OFF}  engine: {r['engineUsed'] or '?'}"
          f"   app: {r['appName'] or '?'}\n")
    print(f"  {BOLD}you meant   {OFF}{meant}")
    print(f"  {BOLD}engine heard{OFF}{r['rawText']}")
    if r.get("cleanupProposed") and r["cleanupProposed"] != r["rawText"]:
        print(f"  {BOLD}AI proposed {OFF}{r['cleanupProposed']}")
    print(f"  {BOLD}you got     {OFF}{r['cleanText']}")
    if r.get("cleanupDecision"):
        note = f" — {r['cleanupRejectReason']}" if r.get("cleanupRejectReason") else ""
        print(f"  {DIM}guard: {r['cleanupDecision']}{note}{OFF}")

    # --- assign blame -------------------------------------------------------
    print(f"\n{BOLD}What went wrong{OFF}\n")
    heard_added, heard_missed = diff(meant, r["rawText"])
    verdicts = []
    if heard_added or heard_missed:
        print(f"  {RED}THE ENGINE MISHEARD YOU.{OFF}")
        if heard_missed: print(f"    it missed : {', '.join(heard_missed)}")
        if heard_added:  print(f"    it added  : {', '.join(heard_added)}")
        print(f"    {DIM}Fix: if these are NAMES or product words, add them in")
        print(f"    Settings ▸ Vocabulary — that is a deterministic fix, no AI involved.")
        print(f"    Otherwise this is raw transcription accuracy: measure it with")
        print(f"    Scripts/wer_session.sh, do not tune anything on one example.{OFF}")
        verdicts.append("engine")
    else:
        print(f"  {GRN}The engine heard you correctly.{OFF}")

    app_added, app_removed = diff(r["rawText"], r["cleanText"])
    # A raw->clean difference is NORMAL: filler removal, vocabulary substitution
    # and every accepted grammar repair all change words legitimately. Only a
    # difference the guard REFUSED is a breach. Calling ordinary cleanup a defect
    # would fill the regression corpus with false verdicts as ground truth.
    guard_breach = (app_added or app_removed) and r.get("cleanupDecision") == "rejected"
    if guard_breach:
        print(f"\n  {RED}THE APP CHANGED YOUR WORDS AFTER HEARING THEM.{OFF}")
        if app_removed: print(f"    removed: {', '.join(app_removed)}")
        if app_added:   print(f"    added  : {', '.join(app_added)}")
        print(f"    {DIM}This should be impossible — the guard exists to stop exactly this.")
        print(f"    It is a defect. This report is the test case for it.{OFF}")
        verdicts.append("guard-leak")
    elif app_added or app_removed:
        print(f"\n  {YEL}Cleanup changed some words — and the guard allowed it.{OFF}")
        if app_removed: print(f"    removed: {', '.join(app_removed)}")
        if app_added:   print(f"    added  : {', '.join(app_added)}")
        print(f"    {DIM}Normal: fillers, your vocabulary list, or an accepted grammar")
        print(f"    fix. If any of these were WRONG, that is the guard being too")
        print(f"    permissive — worth a look, but not a breach.{OFF}")
        verdicts.append("cleanup-changed")
    elif r.get("cleanupDecision") == "rejected":
        print(f"\n  {YEL}The AI offered a fix and the guard refused it.{OFF}")
        print(f"    {DIM}You kept your own words — safe, but you also lost the repair.")
        print(f"    If the AI's version was RIGHT, that is the guard being too strict:")
        print(f"    a policy decision, not a bug. This report records it as evidence.{OFF}")
        verdicts.append("guard-too-strict")
    return verdicts or ["unclear"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-m", "--meant", help="what you actually said")
    ap.add_argument("--pick", action="store_true", help="choose from the last 10")
    a = ap.parse_args()
    if not os.path.exists(DB): sys.exit(f"no history at {DB}")
    recent = rows(10 if a.pick else 1)
    if not recent: sys.exit("no dictations recorded")
    r = recent[0]
    if a.pick:
        for i, x in enumerate(recent):
            when = datetime.datetime.fromtimestamp(x["createdAt"]).strftime("%H:%M")
            print(f"  [{i}] {when}  {x['cleanText'][:88]}")
        r = recent[int(input("\nwhich one? ") or 0)]
    meant = a.meant or input(f"\n{BOLD}What did you actually say?{OFF}\n> ").strip()
    if not meant: sys.exit("nothing to compare against")
    verdicts = show(r, meant)
    os.makedirs(os.path.dirname(CORPUS), exist_ok=True)
    with open(CORPUS, "a") as f:
        f.write(json.dumps({
            "at": datetime.datetime.fromtimestamp(r["createdAt"]).isoformat(),
            "meant": meant, "heard": r["rawText"], "delivered": r["cleanText"],
            "proposed": r.get("cleanupProposed"), "decision": r.get("cleanupDecision"),
            "reason": r.get("cleanupRejectReason"), "engine": r["engineUsed"],
            "verdicts": verdicts}, ensure_ascii=False) + "\n")
    n = sum(1 for _ in open(CORPUS))
    print(f"\n{DIM}saved to {CORPUS} ({n} reports) — this is now a"
          f" regression case and WER data on your voice.{OFF}\n")

if __name__ == "__main__":
    main()
