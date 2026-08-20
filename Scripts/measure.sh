#!/usr/bin/env bash
# ONE command that measures whether the bigger speech model hears Yoni better.
#
# Everything is guided: it restarts the app, waits for the engine, shows the
# lines to read a few at a time, checks the count, runs both models over the
# SAME recordings and prints the answer in plain English. No other commands.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$HOME/Library/Application Support/VoiceFlow/Benchmark"
REF="$ROOT/docs/wer-reference-long.txt"
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; O=$'\033[0m'

pause() { echo; read -r -p "${B}Press RETURN when you're ready…${O}" _ </dev/tty; echo; }

echo
echo "${B}════════════════════════════════════════════════════════════${O}"
echo "${B}  Does the bigger Whisper model hear YOU better?${O}"
echo "${B}════════════════════════════════════════════════════════════${O}"
echo
echo "  You'll read some sentences out loud, dictating them with VoiceFlow"
echo "  exactly the way you normally dictate."
echo
echo "  Your recordings then get transcribed TWICE — once by the small model"
echo "  we use now, once by the big one — and scored against what you were"
echo "  asked to say. Same audio both times, so the only difference is the"
echo "  model."
echo
echo "  ${D}Takes about 20 minutes. You can stop and come back — nothing is lost.${O}"
echo "  ${D}Audio never leaves this Mac, and step 5 deletes it.${O}"
pause

# ── 1. arm ───────────────────────────────────────────────────────────────────
echo "${B}[1/5] Getting VoiceFlow ready…${O}"
osascript -e 'quit app "VoiceFlow"' >/dev/null 2>&1
sleep 2
defaults write com.voiceflow.dictation benchmarkRetainCaptures -bool YES
rm -rf "$CORPUS"; mkdir -p "$CORPUS"
open -a VoiceFlow
echo "  restarted, and it will now keep your recordings for the test"

# ── 2. wait for the engine ───────────────────────────────────────────────────
echo
echo "${B}[2/5] Waiting for the speech engine to load…${O}"
echo "  ${D}This matters: anything you dictate before it's ready is NOT saved,${O}"
echo "  ${D}and that would quietly ruin the whole measurement.${O}"
# `log` can be shadowed by a shell function, which made this wait forever while
# the engine had in fact been ready for minutes. Use the real binary, and never
# leave him stuck: after a minute, just ask him.
READY=no
for i in $(seq 1 15); do
  if /usr/bin/log show --last 15m --predicate 'process == "VoiceFlow"' --info 2>/dev/null \
     | grep -q "Whisper ready"; then READY=yes; break; fi
  printf "\r  still loading… %ds " $((i*4)); sleep 4
done
echo
if [[ "$READY" != yes ]]; then
  echo "  ${Y}Can't confirm automatically — so please look for me:${O}"
  echo "  Open ${B}VoiceFlow ▸ Settings${O} and find ${B}High Accuracy${O}."
  read -r -p "  Does it say Ready? [y/N] " ok </dev/tty
  [[ "$ok" == y || "$ok" == Y ]] || { echo "  Wait for it to say Ready, then run this again."; exit 1; }
  READY=yes
fi
echo "  ${G}engine ready${O}"

# ── 3. read ──────────────────────────────────────────────────────────────────
TOTAL="$(grep -c . "$REF")"
echo
echo "${B}[3/5] Now read ${TOTAL} lines — one dictation each${O}"
echo
echo "  ${B}How:${O} click into any text box (Notes, this terminal, anywhere),"
echo "  hold your dictation key, read ONE line, release. Then the next."
echo
echo "  ${B}Speak normally.${O} Do not slow down or over-pronounce — that would"
echo "  measure a voice you never actually use."
echo
echo "  ${D}If a line comes out wrong, just carry on. Mistakes are the point.${O}"
pause

n=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  n=$((n+1))
  printf "  ${B}%3d.${O} %s\n" "$n" "$line"
  if (( n % 10 == 0 && n < TOTAL )); then
    HAVE="$(ls "$CORPUS" 2>/dev/null | wc -l | tr -d ' ')"
    echo
    echo "  ${D}── recorded so far: ${HAVE} of ${TOTAL} ──${O}"
    read -r -p "  ${B}RETURN for the next 10, or type q to stop here: ${O}" k </dev/tty
    [[ "$k" == q ]] && break
    echo
  fi
done < "$REF"

# ── 4. the answer ────────────────────────────────────────────────────────────
HAVE="$(ls "$CORPUS" 2>/dev/null | wc -l | tr -d ' ')"
echo
echo "${B}[4/5] You recorded ${HAVE} of ${TOTAL} lines.${O}"
if [[ "$HAVE" -lt 5 ]]; then
  echo "  ${R}Too few to measure anything. Run this again when you have time.${O}"
  exit 1
fi
if [[ "$HAVE" -ne "$TOTAL" ]]; then
  echo "  ${Y}Not all of them — so I'll score only the first ${HAVE} lines.${O}"
  head -n "$HAVE" "$REF" > "$CORPUS/../bench-ref-partial.txt"
  REF="$CORPUS/../bench-ref-partial.txt"
fi
echo "  Transcribing your recordings with both models. This takes a few minutes."
echo
BENCH_REF="$REF" bash "$ROOT/Scripts/bench_session.sh" models
RESULT=$?

# ── 5. clean up ──────────────────────────────────────────────────────────────
echo
echo "${B}[5/5] Done measuring.${O}"
read -r -p "  Delete the recordings and stop keeping audio? [Y/n] " ans </dev/tty
if [[ "${ans:-Y}" != n && "${ans:-Y}" != N ]]; then
  defaults write com.voiceflow.dictation benchmarkRetainCaptures -bool NO
  rm -rf "$CORPUS"
  osascript -e 'quit app "VoiceFlow"' >/dev/null 2>&1; sleep 2; open -a VoiceFlow
  echo "  ${G}recordings deleted, VoiceFlow back to normal${O}"
else
  echo "  ${Y}Kept. Run this again later, or delete: rm -rf \"$CORPUS\"${O}"
fi
echo
echo "  ${B}Send Claude the result above and it will decide what to change.${O}"
echo
exit $RESULT
