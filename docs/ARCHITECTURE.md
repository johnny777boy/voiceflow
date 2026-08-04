# VoiceFlow — Architecture

## Goals

1. **Testable core.** All decision logic (cleanup, destination protection,
   insertion planning, history, orchestration) lives in `VoiceFlowCore` behind
   protocols, with no dependency on AppKit/AVFoundation/Speech. This is what the
   test suite exercises.
2. **Thin platform layer.** `VoiceFlowApp` implements the protocols with real
   macOS frameworks and provides the SwiftUI menu-bar UI. It contains no business
   logic worth unit-testing — only glue.
3. **Safety first.** The app never sends or executes anything; it re-verifies the
   destination before every insertion and never touches a secure field.

## Package targets

```
VoiceFlowCore  (library)      pure logic, links libsqlite3
VoiceFlowApp   (executable)   @main SwiftUI app, depends on VoiceFlowCore
VoiceFlowTestKit (library)    tiny XCTest-free assertion harness
VoiceFlowTests (executable)   runs the suite; exits non-zero on failure
```

> **Why a custom test runner?** This machine has only the Command Line Tools,
> whose SDK vends neither `XCTest` nor `swift-testing`. Rather than block on a
> full Xcode install, the suite is a normal executable target on top of
> `VoiceFlowTestKit`. `swift run VoiceFlowTests` behaves like `swift test` for CI.

## The protocol seams (abstractions)

Every subsystem the spec calls out is a protocol in `VoiceFlowCore/Protocols`,
with a real implementation in `VoiceFlowApp/Platform` and a mock in the tests:

| Protocol | Production impl | Purpose |
|----------|-----------------|---------|
| `AudioRecording` | `AudioEngineRecorder` (AVAudioEngine) | Mic capture |
| `Transcribing` | `SpeechTranscriber` (SFSpeechRecognizer) | Speech → text |
| `CleanupProviding` | `CleanupPipeline` / `RuleBasedCleanup` / `LLMCleanupProvider` | Text cleanup |
| `TextInserting` | `AccessibilityTextInserter` | Deliver text |
| `ActiveAppProviding` | `WorkspaceActiveAppProvider` (NSWorkspace + AX) | Destination capture |
| `HotkeyManaging` | `GlobalHotkeyManager` (CGEvent tap) | Global hotkey |
| `HistoryStoring` | `SQLiteHistoryStore` / `InMemoryHistoryStore` | Persistence |
| `SecureStoring` | `KeychainStore` | API-key storage |

## The workflow (`DictationController`)

`DictationController` is an `actor` that ties the seams together:

```
beginRecording()
  ├─ activeApp.captureSnapshot()   → store `original` destination
  └─ audio.startRecording()

finishRecording() async
  ├─ audio.stopRecording()         → AudioCapture
  ├─ transcriber.transcribe(...)   → raw text  (empty ⇒ throws emptyTranscript)
  ├─ resolve mode (per-app default)
  ├─ cleanup.clean(raw, context)   → clean text
  ├─ activeApp.captureSnapshot()   → `current` destination
  ├─ DestinationGuard.makePlan(original, current, capabilities, forceCopyOnly)
  │     ├─ secure field       ⇒ copy-only, willInsert=false
  │     ├─ destination changed⇒ copy-only, willInsert=false
  │     └─ verified           ⇒ InsertionPlanner: AX > paste > copy-only
  ├─ deliver: insert(...) or copyToClipboard(...)   (insert failure ⇒ copy fallback)
  └─ history.save(record); history.trim(limit)
```

The controller is deliberately the only place that sequences the pipeline, so
the ordering and safety guarantees are provable in one place.

## Cleanup engine

- `VocabularyReplacer` — single left-to-right pass, longest-match-first,
  word-boundary aware; written forms are never re-scanned.
- `TextNormalizer` — pure whitespace/filler/capitalization/punctuation transforms.
- `RuleBasedCleanup` — composes the above per `DictationMode` × `CleanupStrength`.
  Code mode keeps commands literal (no forced period, no spoken-punctuation → symbol).
- `CleanupPipeline` — runs the rule engine, then optionally an LLM refinement.
  The LLM stage is best-effort: any failure (or missing key) falls back to the
  deterministic result, so a missing secret never blocks dictation.

## Destination protection

`DestinationSnapshot.matches(_:)` requires the **application** to match; window
titles and element identifiers are soft signals (editors/terminals mutate their
titles constantly). Secure input (`AXSecureTextField`) is detected at capture
time and again at capability time; either one forces copy-only.

## Persistence

- `SQLiteHistoryStore` uses the system `libsqlite3` C API directly (no external
  dependency), with prepared statements and `SQLITE_TRANSIENT` bindings.
- `SettingsStore` persists `AppSettings` as pretty-printed JSON under
  `~/Library/Application Support/VoiceFlow/`.
- `KeychainStore` stores the optional API key via `SecItem` (`kSecClassGenericPassword`).

## Concurrency

The package builds under the **Swift 6 language mode** (strict concurrency) with
zero warnings. The controller is an `actor`; stores use `NSLock`; the UI layer is
`@MainActor`. The hotkey callback (main run loop) hops onto the actor via `Task`.
