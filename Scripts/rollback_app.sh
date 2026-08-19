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

# Sorted by NAME, not mtime — ditto copies the source's mtime, so `ls -t` here
# would confidently restore the OLDER build while reporting it as the newest.
NEWEST="$({ ls -d "$ARCHIVE"/VoiceFlow-*.app 2>/dev/null || true; } | sort -r | head -1)"
[[ -n "$NEWEST" ]] || { echo "No archived builds in $ARCHIVE" >&2; exit 1; }

if [[ "${1:-}" == "--list" ]]; then
  echo "Archived builds (newest first):"
  { ls -d "$ARCHIVE"/VoiceFlow-*.app 2>/dev/null || true; } | sort -r | while read -r b; do
    # Print the stamp parsed from the NAME; the file's mtime is the app's build
    # time, which is misleading here.
    name="$(basename "$b")"; stamp="${name#VoiceFlow-}"; stamp="${stamp%%-*}"
    printf "  %-46s archived %s\n" "$name" "$stamp"
  done
  echo
  echo "Currently installed: $(cat "$ARCHIVE/.current-sha" 2>/dev/null || echo unknown)"
  exit 0
fi

if [[ -n "${1:-}" ]]; then TARGET="$ARCHIVE/$1"; else TARGET="$NEWEST"; fi
[[ -d "$TARGET" ]] || { echo "error: $TARGET not found (try --list)" >&2; exit 1; }
# Prove the archive is a runnable bundle BEFORE destroying the installed app —
# otherwise a partial archive turns "roll back" into "now you have no app".
[[ -x "$TARGET/Contents/MacOS/VoiceFlow" ]] || {
  echo "error: $(basename "$TARGET") looks incomplete — refusing to replace a working app" >&2; exit 1; }

osascript -e 'quit app "VoiceFlow"' 2>/dev/null || true
sleep 2; pkill -x VoiceFlow 2>/dev/null || true; sleep 1
rm -rf "$DEST"; ditto "$TARGET" "$DEST"; open -a "$DEST"
# Keep the sha marker honest, or the NEXT archive is labelled with the commit of
# a build that is no longer installed — wrong precisely after something broke.
RESTORED="$(basename "$TARGET")"; RESTORED="${RESTORED%.app}"; RESTORED="${RESTORED##*-}"
echo "$RESTORED" > "$ARCHIVE/.current-sha"
echo "==> rolled back to $(basename "$TARGET") and relaunched"
