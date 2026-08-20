#!/usr/bin/env bash
# The whole testing system in one command, no reading required.
#
# Prints a report card on how VoiceFlow served its owner since the last
# check-up, from data the app already records — no scripts to read aloud, no
# reference transcripts, no effort. Ends with one verdict line.
set -uo pipefail
DB="$HOME/Library/Application Support/VoiceFlow/history.sqlite"
CONF="$HOME/Library/Application Support/VoiceFlow/personal-confusions.json"
STAMP="$HOME/Library/Application Support/VoiceFlow/.last-checkup"
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; O=$'\033[0m'
SINCE=$(cat "$STAMP" 2>/dev/null || echo 0)
NOW=$(date +%s)

python3 - "$DB" "$CONF" "$SINCE" <<'PY'
import sqlite3, sys, json, re, os, datetime
db, conf, since = sys.argv[1], sys.argv[2], float(sys.argv[3])
B,G,Y,R,O = "\033[1m","\033[32m","\033[33m","\033[31m","\033[0m"
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
rows = list(con.execute(
    "select rawText, cleanText, engineUsed, cleanupDecision, editedAfterInsert, createdAt "
    "from transcripts where createdAt > ? order by createdAt", (since,)))
if not rows:
    print(f"\n{B}Nothing dictated since the last check-up.{O} Nothing to judge.\n"); sys.exit(0)
n = len(rows)
if n < 10:
    print(f"\n{B}Only {n} dictations since the last check-up{O} — too few to grade fairly.")
    print("Keep dictating and run this again after a real day of use.\n"); sys.exit(0)
first = datetime.datetime.fromtimestamp(rows[0][5]).strftime("%b %d")
whisper = sum(1 for r in rows if r[2] == "whisper")
edited = sum(1 for r in rows if r[4])
repaired = sum(1 for r in rows if r[3] in ("accepted","partial") and r[0] != r[1])
runons = 0
for r in rows:
    sents = [s for s in re.split(r'(?<=[.!?])\s+', r[1].strip()) if s.strip()]
    if max((len(s.split()) for s in sents), default=0) > 45: runons += 1
rules = []
if os.path.exists(conf):
    rules = json.load(open(conf))
retries = sum(x.get("sightings",1) for x in rules)
ready = [x for x in rules if x.get("sightings",1) >= 2]

print(f"\n{B}VoiceFlow report card{O}  ({n} dictations since {first})\n")
def line(ok, label, detail):
    mark = f"{G}✓{O}" if ok else f"{R}✗{O}"
    print(f"  {mark}  {label:<34}{detail}")
line(whisper >= n*0.9, "Best engine served you", f"{whisper}/{n}")
line(edited <= max(1, n*0.1), "You had to fix its output", f"{edited}/{n} times")
line(runons <= max(1, n*0.05), "Giant run-on sentences", f"{runons}")
line(True, "Grammar quietly repaired", f"{repaired} dictations")
line(True, "Errors it caught from your retries", f"{retries}")
problems = []
if whisper < n*0.9: problems.append("the accurate engine missed dictations")
if edited > max(1, n*0.1): problems.append("you edited too often")
if runons > max(1, n*0.05): problems.append("run-ons are back")
print()
if not problems:
    print(f"  {G}{B}VERDICT: healthy. Keep dictating — nothing needed from you.{O}")
else:
    print(f"  {R}{B}VERDICT: needs attention — {'; '.join(problems)}.{O}")
    print(f"  Tell Claude: \"run the deep check\" and it will diagnose from the data.")
if ready:
    print(f"\n  {Y}{len(ready)} repeated mistake(s) ready to become automatic fixes — ask Claude to review them.{O}")
print()
PY
echo "$NOW" > "$STAMP"
