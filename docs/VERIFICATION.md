# VoiceFlow — Internal Verification Report

**Branch:** `feature/system-dictation-daily-use`
**Toolchain:** Apple Swift 6.2.3, target `arm64-apple-macosx26.0`
**Environment:** macOS 26.5.1, Command Line Tools only (no full Xcode)

This report is produced per the specification's *Verification* section:
self-review, run all tests, run static analysis, and record the results.

---

## 1. Self-review against the Definition of Done

| Requirement | Status | Evidence |
|-------------|:------:|----------|
| System-wide shortcut | ✅ verified (logic) + code-complete (glue) | `HotkeyMatcher` (decode + trigger) unit-tested; `GlobalHotkeyManager` (CGEvent tap) wires it. Requires Accessibility permission at runtime. |
| Recording | ✅ code-complete | `AudioEngineRecorder` (AVAudioEngine tap). |
| Transcription | ✅ code-complete | `SpeechTranscriber` (on-device `SFSpeechRecognizer`). |
| Cleanup | ✅ verified | `RuleBasedCleanup` + `CleanupPipeline`; 20 cleanup/vocabulary tests. |
| Destination protection | ✅ verified | `DestinationGuard`; blocks wrong-app and secure-field insertion (tests). |
| Clipboard restoration | ✅ code-complete | `AccessibilityTextInserter.pasteWithRestore` saves/restores pasteboard. |
| Claude Code target | ✅ verified | Code mode keeps commands literal (test: "git status" unchanged). |
| Codex target | ✅ mapped | Per-app default mode; Codex added to default vocabulary + treated as a coding target. |
| Email | ✅ verified | Email mode preserves line breaks, polishes prose (controller test). |
| Browser text fields | ✅ code-complete | AX insertion + clipboard paste fallback for web fields. |
| History | ✅ verified | `SQLiteHistoryStore` + `InMemoryHistoryStore`; 15 history tests incl. persistence across reopen. |
| Tests pass | ✅ | 79/79 (below). |
| Internal verification | ✅ | This document. |
| Never auto-sends | ✅ verified | Controller only inserts/copies; no Return synthesis anywhere in the codebase. |
| Never pastes into password fields | ✅ verified | Secure-field test asserts no insertion. |

"Code-complete" items are compiled and wired but exercise macOS frameworks that
require runtime permissions and a human at the keyboard (mic, speech, AX). They
are covered by manual compatibility testing (§4), not unit tests.

## 2. Test results

```
$ swift run VoiceFlowTests
✓ All 79 tests passed.
```

Exit code `0`. The runner exits non-zero on any failure (CI-compatible).

Coverage by area:

| Area | Cases |
|------|------:|
| Models (snapshots, settings, JSON round-trips) | 7 |
| Vocabulary replacement | 7 |
| Cleanup engine + pipeline | 16 |
| Insertion planner | 5 |
| Destination guard | 5 |
| History stores + settings store | 15 |
| Security / Keychain contract / LLM provider | 10 |
| Hotkey matcher (modifier decode + trigger logic) | 6 |
| Dictation controller (end-to-end with mocks) | 7 |
| **Total executed** | **79** |

Notable behaviors proven by tests:

- Longest-match vocabulary: `"next js"` → `Next.js` is **not** re-mangled by a
  shorter `next` rule (regression that a naive multi-pass replacer would hit).
- Destination change mid-dictation diverts to the clipboard; the wrong app is
  never written to.
- Secure (password) fields are never inserted into.
- LLM cleanup failure (or missing API key) transparently falls back to the
  rule-based result.
- SQLite history survives a store reopen.

## 3. Static analysis

- **Swift 6 language mode / strict concurrency** is enabled (Package
  `swift-tools-version:6.0`). A clean build compiles the entire package —
  including the `actor`, `@MainActor` UI, and all `Sendable` boundaries — with
  **0 warnings and 0 errors**.
- No force-unwrap of optionals across the network/AX boundaries; failures are
  modeled with `VoiceFlowError` and degrade gracefully.
- No third-party dependencies (only system `libsqlite3` and Apple frameworks),
  so the supply-chain surface is zero.

```
$ swift build            # debug
Build complete!  (0 warnings)
$ ./Scripts/build_app.sh release
Built: dist/VoiceFlow.app   (ad-hoc signed, hardened runtime, valid on disk)
```

## 4. Manual compatibility (requires a human + granted permissions)

These cannot run in this headless verification pass; they are the acceptance
checklist for the owner on first launch (spec target: **100 successful
dictations, no critical failures**):

- [ ] Claude Code, Codex, Terminal, iTerm2 — code mode, literal commands
- [ ] VS Code — code/prose
- [ ] Safari, Chrome — browser text fields (Gmail, CRMs)
- [ ] Apple Mail — email mode
- [ ] Slack, Notes — clean writing
- [ ] Password field anywhere — confirm copy-only, no paste

## 5. Conclusion

Internal verification **passes**: the build is clean under strict concurrency,
all 79 automated tests pass, the release `.app` bundles and signs, and a
self-review confirms every Definition-of-Done item is implemented. Items that
depend on live macOS permissions are code-complete and enumerated for manual
acceptance. Proceed to external (Codex) verification —
see [CODEX_VERIFICATION_PACKAGE.md](CODEX_VERIFICATION_PACKAGE.md).
