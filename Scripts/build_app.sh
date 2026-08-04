#!/usr/bin/env bash
# Build VoiceFlow.app from the Swift Package Manager executable.
#
# This machine has only the Command Line Tools (no full Xcode), so we assemble
# the .app bundle by hand around the `swift build` product and ad-hoc codesign it.
# Ad-hoc signing is enough for a personal, locally-run app; the OS will still
# prompt for Microphone, Speech Recognition, and Accessibility on first use.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="VoiceFlow"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/bundle/Info.plist" "$APP/Contents/Info.plist"

echo "==> Ad-hoc codesigning…"
codesign --force --deep \
  --sign - \
  --entitlements "$ROOT/bundle/VoiceFlow.entitlements" \
  --options runtime \
  "$APP" 2>/dev/null || \
codesign --force --deep --sign - \
  --entitlements "$ROOT/bundle/VoiceFlow.entitlements" \
  "$APP"

echo "==> Verifying…"
codesign --verify --verbose "$APP" || true

echo ""
echo "Built: $APP"
echo "Run with: open \"$APP\"   (or)   \"$APP/Contents/MacOS/$APP_NAME\""
echo ""
echo "First launch: grant Microphone, Speech Recognition, and Accessibility"
echo "in System Settings ▸ Privacy & Security when prompted."
