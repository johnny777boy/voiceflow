# VoiceFlow — External Verification Package (for Codex)

> **Role:** Codex acts as an **external reviewer**. Please independently verify
> the work below. If you find problems, list them concretely (file:line where
> possible) so they can be fixed inside the worktree; verification then repeats
> until clean. Do not merge — the owner does that.

**Branch under review:** `feature/system-dictation-daily-use`
**Base:** `main`
**Toolchain:** Swift 6.2.3 · macOS 26.5.1 · arm64 · Command Line Tools only (no full Xcode)

How to reproduce locally:

```bash
git checkout feature/system-dictation-daily-use
swift build            # expect: Build complete, 0 warnings
swift run VoiceFlowTests   # expect: "All 79 tests passed", exit 0
./Scripts/build_app.sh release   # expect: dist/VoiceFlow.app, ad-hoc signed
```

---

## 1. Architecture summary

A macOS menu-bar push-to-talk dictation app. The workflow is:

```
Hold hotkey → record → transcribe → clean → RE-VERIFY destination → insert/copy
```

Two Swift Package targets carry the design:

- **`VoiceFlowCore`** — all decision logic behind protocols, no UI/AV/AX imports.
  This is what the tests exercise.
- **`VoiceFlowApp`** — the `@main` SwiftUI app: protocol implementations using
  AVAudioEngine / SFSpeechRecognizer / CGEvent tap / Accessibility / NSWorkspace /
  Keychain, plus the menu-bar UI, settings, and overlay.

Testing uses a custom XCTest-free harness (`VoiceFlowTestKit`) run as an
executable (`VoiceFlowTests`), because the CLT SDK ships neither XCTest nor
swift-testing. `swift run VoiceFlowTests` exits non-zero on failure.

The orchestrator is `DictationController` (an `actor`). It is the single place
that sequences the pipeline and enforces the safety rules:

- Captures the destination at record start; **re-captures and compares** before
  insertion.
- `DestinationGuard` forces **copy-only** if the app changed or the field is
  secure (password). It never inserts into the wrong app or a secure field.
- `InsertionPlanner` priority: Accessibility → clipboard-restore paste → copy-only.
- **The app never synthesizes Return / never sends / never runs a command.**

See `docs/ARCHITECTURE.md` for the full design.

## 2. Files changed

65 files added + README updated on the branch (0 deletions vs `main`). By area:

| Area | Files | Key contents |
|------|:----:|--------------|
| `Sources/VoiceFlowCore/Models` | 8 | `DictationMode`, `DestinationSnapshot` (+`matches`), `InsertionStrategy`, `VocabularyEntry`, `TranscriptRecord`, `AppSettings`/`HotkeyConfiguration`, `PerAppBehavior`, `CleanupStrength` |
| `Sources/VoiceFlowCore/Protocols` | 8 | The eight abstraction seams |
| `Sources/VoiceFlowCore/Cleanup` | 6 | `VocabularyReplacer`, `TextNormalizer`, `RuleBasedCleanup`, `CleanupPipeline`, `LLMCleanupProvider`(+`AnthropicTransport`), `CleanupPromptBuilder` |
| `Sources/VoiceFlowCore/Destination` | 1 | `DestinationGuard` |
| `Sources/VoiceFlowCore/Insertion` | 1 | `InsertionPlanner` |
| `Sources/VoiceFlowCore/History` | 3 | `SQLiteHistoryStore`, `InMemoryHistoryStore`, `SettingsStore` |
| `Sources/VoiceFlowCore/Security` | 1 | `KeychainStore` |
| `Sources/VoiceFlowCore/Support` | 6 | errors, logging, clock, app paths, info, `HotkeyMatcher`; `DictationController` at core root |
| `Sources/VoiceFlowApp/Platform` | 7 | `AudioEngineRecorder`, `SpeechTranscriber`, `GlobalHotkeyManager`, `AccessibilityTextInserter`, `WorkspaceActiveAppProvider`, `AccessibilityBridge`, `LoginItemManager` |
| `Sources/VoiceFlowApp/UI` + root | 6 | `AppMain`, `AppCoordinator`, `MenuContentView`, `SettingsView`, `OverlayController`, `OverlayView` |
| `Sources/VoiceFlowTests` | 10 | Model, vocabulary, cleanup, planner, guard, history, security, hotkey, controller tests + mocks |
| `Sources/VoiceFlowTestKit` | 2 | `TestSuite`, `blockingAwait` |
| `bundle/`, `Scripts/`, `Package.swift` | 4 | Info.plist, entitlements, build script, manifest |

Commits (logical milestones):

```
9628b01 feat: foundation (models, protocols) + cleanup engine
84eb93d feat: destination protection, insertion planner, history + settings store
8817a9e feat: security/keychain, optional LLM cleanup, dictation controller
428347d feat: macOS platform layer, menu bar app, and .app bundling
```

## 3. Test results

`swift run VoiceFlowTests` → **79/79 passed**, exit 0. `swift build` → **0 warnings**
under Swift 6 strict concurrency. Release `.app` builds and ad-hoc codesigns
(hardened runtime, valid on disk). Full breakdown in `docs/VERIFICATION.md`.

## 4. Remaining risks (please scrutinize)

1. **Global hotkey correctness.** The pure matching logic (Carbon-mask decode +
   trigger decision) is now factored into `HotkeyMatcher` in the core and is
   **unit-tested** (6 cases). What remains untested is the live-event glue in
   `GlobalHotkeyManager`: modifier-release while the main key is still down; the
   default ⌥Space possibly conflicting with system input-source switching;
   `.listenOnly` tap semantics. *(These need a live event tap + AX permission.)*
2. **Accessibility insertion across apps.** `AccessibilityTextInserter` tries
   `kAXSelectedTextAttribute` then `kAXValueAttribute`. Electron/Chromium web
   views and some Cocoa text views expose AX inconsistently; the clipboard-paste
   fallback covers most, but please sanity-check the fallback ordering and the
   150 ms clipboard-restore delay (a race window exists if the user copies during
   that window).
3. **Speech buffer path.** `SpeechTranscriber` reconstructs a single PCM buffer
   from captured samples and runs one non-streaming recognition. Very long
   dictations or a sample-rate mismatch between capture and the recognizer are
   the risk areas.
4. **Secure-field detection completeness.** Detection relies on
   `AXSecureTextField` subrole/role. A non-standard secure field that doesn't
   advertise that subrole could be missed. The design mitigates by *also* honoring
   per-app `forceCopyOnly`.
5. **Concurrency at the hotkey→actor boundary.** The tap callback hops to
   `@MainActor` then into the `DictationController` actor via `Task`. Rapid
   press/release could interleave `begin`/`finish`; controller guards with
   `pendingSnapshot`/`isRecording`, but please review for a lost-update.

## 5. Known limitations

- **Requires manual permission grants** (Microphone, Speech Recognition,
  Accessibility) on first launch — expected for this class of app; the spec lists
  manual macOS permissions as an allowed stop condition.
- **Ad-hoc signed only.** No Developer ID / notarization (no full Xcode / cert in
  this environment). Fine for personal local use; Gatekeeper will warn on first open.
- **On-device transcription quality** depends on the installed macOS speech
  assets for the chosen locale.
- **LLM cleanup** requires the user to add an Anthropic API key (Keychain);
  absent a key it silently uses the offline rule engine (by design). Default
  cleanup model is `claude-haiku-4-5` (latency-oriented), configurable.
- **Launch-at-login** is wired via `SMAppService` (`LoginItemManager`), applied
  at startup and on settings change. It only takes effect from the installed
  `.app` bundle (SMAppService requires a bundle), not a bare `swift run`.

## 6. Suggested review checklist for Codex

- [ ] Reproduce: `swift build` (0 warnings) and `swift run VoiceFlowTests` (79 pass).
- [ ] Read `DictationController.finishRecording` — confirm destination is
      re-verified *after* transcription/cleanup and *before* insertion, and that
      every failure path degrades to copy-only (never a wrong-app write).
- [ ] Confirm there is **no** synthetic Return / Enter / message-send anywhere
      (`grep -rn "kVK_Return\|\.enter\|send(" Sources` should find nothing that sends).
- [ ] Audit `AccessibilityTextInserter` for the secure-field guard and the
      clipboard-restore race.
- [ ] Audit `GlobalHotkeyManager.modifiersMatch` / `handle` for the edge cases in §4.1.
- [ ] Audit `VocabularyReplacer` for correctness on overlapping/adjacent phrases
      and regex-special written forms (there are tests — try to break them).
- [ ] Audit `SQLiteHistoryStore` for SQL injection (prepared statements only?),
      resource leaks (every `sqlite3_stmt` finalized?), and the `trim` query.
- [ ] Sanity-check Swift 6 `Sendable`/`@unchecked Sendable` uses in the stores and
      platform impls for real data races.
- [ ] Spot-check the Anthropic request shape in `AnthropicTransport` against the
      current Messages API (endpoint, headers, body).

Report findings as a list; fixes will be applied in the worktree and verification
re-run until clean.

---

## 7. Round 2 — fixes applied in response to review

Codex's first pass (78 tests) confirmed the safety invariant, SQLite hygiene, and
transport shape, and raised **four** defects. All four are now fixed on the branch
(commit follows this doc). Please re-verify:

1. **Secure-field TOCTOU in the AX/paste fallback** — *fixed.*
   `AccessibilityTextInserter.insert` now performs a **last-moment secure-field
   check** (`focusedFieldIsSecure()`) before any AX set or synthetic paste, for
   every non-copy strategy, and `pasteWithRestore` re-checks once more immediately
   before synthesizing Cmd-V (throwing `secureFieldBlocked`, which `insert`
   converts to a copy-only outcome). The AX-fail → paste fallthrough can no longer
   paste into a field that became secure after planning.
   *Verify:* `Sources/VoiceFlowApp/Platform/AccessibilityTextInserter.swift`
   (`insert`, `pasteWithRestore`, `focusedFieldIsSecure`).

2. **Modifier-release while the main key is held** — *fixed.*
   `GlobalHotkeyManager` now also subscribes to `.flagsChanged`, and `handle`
   processes flag changes **before** the key-code guard. On a push-to-talk chord,
   releasing a modifier while the key is still down now emits `.released` via the
   new pure, unit-tested `HotkeyMatcher.shouldEndChord(...)`.
   *Verify:* `GlobalHotkeyManager.handle` + `HotkeyMatcher.shouldEndChord` (test:
   "shouldEndChord: push-to-talk ends when modifiers drop while held").

3. **Toggle autorepeat + begin/finish interleave** — *fixed.*
   Toggle-mode `keyDown` now ignores OS auto-repeat (`keyboardEventAutorepeat`),
   so one physical press = one `.toggled`. `AppCoordinator.beginRecording` /
   `finishRecording` set a synchronous `busy` latch **before** the `await`, so two
   queued toggle tasks can no longer both pass the `isRecording` guard and
   double-enter a transition.
   *Verify:* `GlobalHotkeyManager.handle` (`isRepeat`) + `AppCoordinator` (`busy`).

4. **Speech recognition can hang with no timeout** — *fixed.*
   `SpeechTranscriber.transcribe` now arms a **watchdog** (default 20 s) that
   cancels the recognition task and fails cleanly if no final result/error arrives
   after `endAudio()`. Continuation resumption is guarded by a lock-based
   `ResumeOnce` (the old `finished` flag was mutated from the recognizer's callback
   queue without synchronization); the task is cancelled through a Sendable holder.
   *Verify:* `Sources/VoiceFlowApp/Platform/SpeechTranscriber.swift`.

Post-fix status: `swift build` → **0 warnings**, `swift run VoiceFlowTests` →
**79/79 passed** (added `shouldEndChord` coverage). Release `.app` rebuilds and
signs.

## 8. Round 3 — residual fixes

Codex's second pass found **two residual issues** (one a regression from the
round-2 `busy` latch). Both are now fixed:

1. **`busy` latch dropped `.released` events** (regression) — *fixed.*
   Replaced the latch with an **intent → actual reconciler** in `AppCoordinator`.
   Hotkey events set `recordingIntent` synchronously (never await) and kick
   `reconcile()`, which runs one pass at a time and **re-reads the intent after
   every `await`**. So `press → (release while begin is still awaiting) → begin
   completes` now converges to *not recording* instead of getting stuck. A failed
   begin breaks the loop (`if !isRecording`) to avoid spinning.
   *Verify:* `AppCoordinator.handle` / `reconcile` / `beginRecordingTransition` /
   `finishRecordingTransition`. Trace: press sets intent=true; a release during
   the begin-await sets intent=false; after begin sets `isRecording=true`, the
   loop sees `intent(false) != isRecording(true)` and runs finish → ends idle.

2. **AX-set path didn't re-check the specific focused element** — *fixed.*
   `insertViaAccessibility` now calls `Self.isSecure(focused)` on the exact element
   it fetched and returns `false` (declining the AX write) if it's secure — mirror
   of the paste-path guard. Focus moving to a secure element between the top-level
   guard and the AX set can no longer result in a write.
   *Verify:* `AccessibilityTextInserter.insertViaAccessibility`.

Post-fix status: `swift build` → **0 warnings**, `swift run VoiceFlowTests` →
**79/79 passed**. Release `.app` rebuilds and signs.
