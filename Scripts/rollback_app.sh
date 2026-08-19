#!/usr/bin/env bash
# Restore a previously installed VoiceFlow build, in seconds.
#
#   Scripts/rollback_app.sh          → restore the most recent archived build
#   Scripts/rollback_app.sh --list   → show what is available
#   Scripts/rollback_app.sh <name>   → restore a specific archived build
#
# Portable to the bash 3.2 that ships with macOS (no mapfile/readarray).
set -euo pipefail

ARCHIVE="$HOME/Library/Application Support/VoiceFlow/Backups"
DEST="/Applications/VoiceFlow.app"

NEWEST="$(ls -dt "$ARCHIVE"/VoiceFlow-*.app 2>/dev/null | head -1 || true)"
[[ -n "$NEWEST" ]] || { echo "No archived builds in $ARCHIVE" >&2; exit 1; }

if [[ "${1:-}" == "--list" ]]; then
  echo "Archived builds (newest first):"
  ls -dt "$ARCHIVE"/VoiceFlow-*.app | while read -r b; do
    printf "  %-46s %s\n" "$(basename "$b")" "$(date -r "$b" '+%Y-%m-%d %H:%M')"
  done
  echo
  echo "Currently installed: $(cat "$ARCHIVE/.current-sha" 2>/dev/null || echo unknown)"
  exit 0
fi

if [[ -n "${1:-}" ]]; then TARGET="$ARCHIVE/$1"; else TARGET="$NEWEST"; fi
[[ -d "$TARGET" ]] || { echo "error: $TARGET not found (try --list)" >&2; exit 1; }

osascript -e 'quit app "VoiceFlow"' 2>/dev/null || true
sleep 2; pkill -x VoiceFlow 2>/dev/null || true; sleep 1
rm -rf "$DEST"; ditto "$TARGET" "$DEST"; open -a "$DEST"
echo "==> rolled back to $(basename "$TARGET") and relaunched"
