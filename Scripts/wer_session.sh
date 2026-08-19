#!/usr/bin/env bash
# Measure real transcription accuracy (WER) from the app's own history.
#
# We have never had an accuracy NUMBER — only impressions, which is how a dead
# engine went unnoticed for eight days. This turns a normal dictation session
# into a measurement: read the prompts aloud, then score what the app actually
# produced against what you were asked to say.
#
#   Scripts/wer_session.sh prompts     → print the script to read aloud
#   Scripts/wer_session.sh score       → score the last N dictations against it
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="$HOME/Library/Application Support/VoiceFlow/history.sqlite"
REF="$ROOT/docs/wer-reference.txt"

case "${1:-prompts}" in
  prompts)
    echo "Read each line aloud as ONE dictation, in order. Speak normally."
    echo "Then run: Scripts/wer_session.sh score"
    echo
    nl -ba "$REF"
    ;;
  score)
    COUNT="$(wc -l < "$REF" | tr -d ' ')"
    sqlite3 "$DB" "SELECT rawText FROM transcripts ORDER BY createdAt DESC LIMIT $COUNT;" \
      | tail -r > /tmp/wer-hyp.txt
    echo "Scoring the last $COUNT dictations against the reference…"
    echo "(rawText = what the ENGINE heard, before cleanup — that is the accuracy of transcription)"
    python3 "$ROOT/Scripts/wer.py" "$REF" /tmp/wer-hyp.txt
    ;;
  *) echo "usage: $0 [prompts|score]" >&2; exit 1 ;;
esac
