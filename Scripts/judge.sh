#!/usr/bin/env bash
# Decide the model question from YOUR NORMAL WORK — no script to read.
#
# Reading 154 sentences aloud is a bad ask, and read speech is not how anyone
# actually dictates. This does it the other way round: you just work, the app
# quietly keeps the audio, and afterwards both models transcribe the SAME
# recordings. Most of the time they agree — those tell us nothing and are
# skipped. You only look at the handful where they DISAGREE, and say which one
# got it right.
#
# That is a forced-choice preference test. It needs no reference transcript at
# all, it measures the speech you really produce, and your effort is a few
# keystrokes instead of twenty minutes of reading.
#
#   Scripts/judge.sh collect   turn on audio keeping, then just work normally
#   Scripts/judge.sh decide    review the disagreements and get the answer
#   Scripts/judge.sh stop      stop keeping audio and delete it
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$HOME/Library/Application Support/VoiceFlow/Benchmark"
OUT="$HOME/Library/Application Support/VoiceFlow/Benchmark-results"
TURBO="openai_whisper-large-v3-v20240930_turbo"
LARGE="openai_whisper-large-v3"
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; O=$'\033[0m'
mkdir -p "$OUT"

case "${1:-help}" in
  collect)
    osascript -e 'quit app "VoiceFlow"' >/dev/null 2>&1; sleep 2
    defaults write com.voiceflow.dictation benchmarkRetainCaptures -bool YES
    mkdir -p "$CORPUS"
    open -a VoiceFlow
    echo
    echo "${B}Now just use VoiceFlow normally.${O}"
    echo
    echo "  Dictate your work, your messages, whatever you were going to do"
    echo "  anyway. Nothing to read, nothing to remember."
    echo
    echo "  The app keeps a copy of the audio so both models can be compared on"
    echo "  the same recordings later. ${D}It stays on this Mac.${O}"
    echo
    echo "  Aim for ${B}30+ dictations${O} — an hour of normal work usually does it."
    echo "  Check anytime:  ${B}Scripts/judge.sh decide${O}"
    echo
    ;;

  decide)
    N="$(ls "$CORPUS" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$N" -lt 5 ]]; then
      echo "Only $N recordings so far — keep working and come back."
      echo "(If this says 0 after you've dictated, tell Claude: audio is not being kept.)"
      exit 1
    fi
    echo "${B}Transcribing your $N recordings with both models…${O}"
    echo "${D}A few minutes. Nothing to do yet.${O}"
    rm -f "$OUT"/judge-*.txt
    swift run -c release --package-path "$ROOT" VoiceFlowBench --audio "$CORPUS" \
      --model "$TURBO" --out "$OUT/judge-small.txt" 2>&1 | grep -E "decoder layers|decode " || true
    swift run -c release --package-path "$ROOT" VoiceFlowBench --audio "$CORPUS" \
      --model "$LARGE" --out "$OUT/judge-big.txt" 2>&1 | grep -E "decoder layers|decode " || true
    if cmp -s "$OUT/judge-small.txt" "$OUT/judge-big.txt"; then
      echo "${R}FATAL: both runs produced identical text — the same model ran twice.${O}"
      exit 1
    fi
    python3 "$ROOT/Scripts/judge.py" "$OUT/judge-small.txt" "$OUT/judge-big.txt"
    ;;

  stop)
    defaults write com.voiceflow.dictation benchmarkRetainCaptures -bool NO
    rm -rf "$CORPUS"
    osascript -e 'quit app "VoiceFlow"' >/dev/null 2>&1; sleep 2; open -a VoiceFlow
    echo "Audio keeping is off and the recordings are deleted."
    ;;

  *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
