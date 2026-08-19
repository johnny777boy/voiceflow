#!/usr/bin/env bash
# Measure real transcription accuracy (WER) from the app's own history.
#
# We have never had an accuracy NUMBER — only impressions, which is how a dead
# engine went unnoticed for eight days. This turns a normal dictation session
# into a measurement: read the prompts aloud, then score what the app actually
# produced against what you were asked to say.
#
#   Scripts/wer_session.sh start       → mark the session start
#   Scripts/wer_session.sh prompts     → print the script to read aloud
#   Scripts/wer_session.sh score       → score THIS session's dictations
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="$HOME/Library/Application Support/VoiceFlow/history.sqlite"
REF="$ROOT/docs/wer-reference.txt"

STAMP_FILE="$HOME/Library/Application Support/VoiceFlow/.wer-session-start"

case "${1:-prompts}" in
  start)
    date +%s > "$STAMP_FILE"
    echo "Session marked. Now: $0 prompts"
    ;;
  prompts)
    date +%s > "$STAMP_FILE"
    echo "Read each line aloud as ONE dictation, in order. Speak normally."
    echo "Then run: Scripts/wer_session.sh score"
    echo
    nl -ba "$REF"
    ;;
  score)
    COUNT="$(grep -c . "$REF")"
    [[ -f "$STAMP_FILE" ]] || { echo "error: run '$0 prompts' first" >&2; exit 1; }
    START="$(cat "$STAMP_FILE")"
    # Only dictations from THIS session. Taking "the last N rows" blindly scored
    # whatever happened to be in history — producing a plausible-looking WRONG
    # number, which is the exact failure this script exists to prevent.
    sqlite3 "$DB" "SELECT rawText FROM transcripts WHERE createdAt > $START ORDER BY createdAt ASC;" > /tmp/wer-hyp.txt
    GOT="$(grep -c . /tmp/wer-hyp.txt || true)"
    if [[ "$GOT" -ne "$COUNT" ]]; then
      echo "WARNING: expected $COUNT dictations since the session started, found $GOT."
      echo "Lines are paired in order, so a mismatch means the score is not trustworthy."
      echo "What was captured:"; nl -ba /tmp/wer-hyp.txt; echo
    fi
    echo "Scoring $GOT dictations against the reference…"
    echo "(rawText = what the ENGINE heard, before cleanup — that is the accuracy of transcription)"
    python3 "$ROOT/Scripts/wer.py" "$REF" /tmp/wer-hyp.txt
    ;;
  *) echo "usage: $0 [prompts|score]" >&2; exit 1 ;;
esac
