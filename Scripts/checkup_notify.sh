#!/usr/bin/env bash
# Run the weekly check-up unattended and show the verdict as a macOS
# notification. This is what the Friday LaunchAgent runs — the owner does
# nothing; the verdict comes to him.
set -uo pipefail
OUT="$("$(dirname "${BASH_SOURCE[0]}")/checkup.sh" 2>/dev/null | sed $'s/\033\\[[0-9;]*m//g')"
VERDICT="$(echo "$OUT" | grep -E "VERDICT:|too few to grade" | head -1 | sed 's/^ *//')"
[[ -z "$VERDICT" ]] && VERDICT="Check-up ran — open the Desktop button for details."
osascript -e "display notification \"$VERDICT\" with title \"VoiceFlow weekly check-up\"" 2>/dev/null
echo "$VERDICT"
