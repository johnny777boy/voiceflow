# VoiceFlow

A native macOS menu-bar app for **system-wide push-to-talk dictation** with
AI-assisted cleanup and destination-protected text insertion. Personal,
macOS-only — not a SaaS product.

## What it does

```
Cursor → Hold hotkey → Record → Release → Transcribe → AI cleanup →
Validate destination → Insert text → You review → You press Enter
```

The app **never** sends a message or runs a command for you. It only places
cleaned text into the field where you started dictating (or the clipboard, if it
can't verify the destination).

## Features

- **Push-to-talk hotkey** (default ⌥Space) that works in any app.
- **On-device transcription** via Apple's `SFSpeechRecognizer` (no cloud, no key).
- **Cleanup modes** — Raw, Clean Writing, Claude Code, Email — with per-app defaults.
- **Optional AI cleanup** via the Anthropic API (key stored in Keychain). Falls
  back to the built-in offline engine when no key is set.
- **Destination protection** — the app re-checks the frontmost app and focused
  field before inserting, and refuses to paste into the wrong app or a password field.
- **Insertion priority** — Accessibility → clipboard-restore paste → copy-only.
- **Custom vocabulary** — spoken → written substitutions (Payload CMS, Next.js, …).
- **History** — raw + clean transcript, app, latency, with copy/delete/clear.

## Requirements

- macOS 14+ (built and tested on macOS 26 / arm64).
- Swift 6.2 toolchain (Command Line Tools is sufficient — no full Xcode needed).

## Build & run

```bash
# Build the .app bundle (release) and ad-hoc codesign it
./Scripts/build_app.sh release
open dist/VoiceFlow.app
```

On first launch, grant **Microphone**, **Speech Recognition**, and
**Accessibility** in System Settings ▸ Privacy & Security. Accessibility is
required for the global hotkey and text insertion.

## Test

```bash
swift run VoiceFlowTests   # runs the full suite; exits non-zero on any failure
```

> The Command Line Tools SDK does not ship XCTest, so the suite is a small
> dependency-free runner (`VoiceFlowTestKit`) built as an executable target. See
> [docs/VERIFICATION.md](docs/VERIFICATION.md).

## Layout

| Path | What |
|------|------|
| `Sources/VoiceFlowCore` | Pure, testable domain logic (models, protocols, cleanup, destination guard, history, security, controller). |
| `Sources/VoiceFlowApp` | The macOS executable: platform implementations + SwiftUI menu-bar UI. |
| `Sources/VoiceFlowTests` | The test suite. |
| `Sources/VoiceFlowTestKit` | Minimal XCTest-free assertion harness. |
| `bundle/` | Info.plist + entitlements for the app bundle. |
| `Scripts/build_app.sh` | Assembles and ad-hoc signs `VoiceFlow.app`. |
| `docs/` | Architecture, verification report, Codex review package, merge instructions. |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.
