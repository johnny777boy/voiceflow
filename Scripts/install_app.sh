#!/usr/bin/env bash
# Install the built app to /Applications, ARCHIVING the current one first.
#
# Every install used to overwrite the working app with no way back — if a build
# regressed, the only recovery was rebuilding from a git tag, and after main went
# stale even that was a downgrade. This keeps the last few installed builds on
# disk so rollback is one command and takes seconds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/dist/VoiceFlow.app"
DEST="/Applications/VoiceFlow.app"
ARCHIVE="$HOME/Library/Application Support/VoiceFlow/Backups"
KEEP=5

[[ -d "$SRC" ]] || { echo "error: $SRC not found — run Scripts/build_app.sh first" >&2; exit 1; }
mkdir -p "$ARCHIVE"

# Archive the app being replaced, stamped with the commit it came from (if known).
if [[ -d "$DEST" ]]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  PREV_SHA="$(cat "$ARCHIVE/.current-sha" 2>/dev/null || echo unknown)"
  FINAL="$ARCHIVE/VoiceFlow-$STAMP-$PREV_SHA.app"
  STAGING="$ARCHIVE/.staging-$STAMP.app"
  # Stage then move: an interrupted or failed copy must never leave a PARTIAL
  # bundle that a later rollback would happily restore over a working app.
  trap 'rm -rf "$STAGING"' EXIT INT TERM
  rm -rf "$STAGING"
  ditto "$DEST" "$STAGING"
  [[ -x "$STAGING/Contents/MacOS/VoiceFlow" ]] || { echo "error: archive copy incomplete; aborting" >&2; exit 1; }
  mv "$STAGING" "$FINAL"
  trap - EXIT INT TERM
  echo "==> archived the previous build as $(basename "$FINAL")"
fi

osascript -e 'quit app "VoiceFlow"' 2>/dev/null || true
sleep 2; pkill -x VoiceFlow 2>/dev/null || true; sleep 1

rm -rf "$DEST"
ditto "$SRC" "$DEST"
git -C "$ROOT" rev-parse --short HEAD > "$ARCHIVE/.current-sha" 2>/dev/null || true
open -a "$DEST"

# Keep only the newest $KEEP archives.
# Sort by NAME (the stamp is zero-padded and sortable), never by mtime: ditto
# preserves the source bundle's mtime, so every archive carries the app's build
# time and `ls -t` would prune the newest.
{ ls -d "$ARCHIVE"/VoiceFlow-*.app 2>/dev/null || true; } | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
  [[ -n "$old" ]] || continue
  rm -rf "$old"; echo "==> pruned $(basename "$old")"
done

echo "==> installed $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) and relaunched"
echo "    roll back anytime:  Scripts/rollback_app.sh"
