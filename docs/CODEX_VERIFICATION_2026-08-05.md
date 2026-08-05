# VoiceFlow — Codex External Verification Package (2026-08-05)

Paste this whole document into Codex (or another independent reviewer) and ask it
to verify the claims and hunt for defects. It is self-contained: it states what the
app does, what changed, how to build/test, the exact files and functions to audit,
the safety invariants that must hold, and the known constraints.

Repo: `github.com/johnny777boy/voiceflow` · Branch: `main` · HEAD: `e753449`
Language: Swift 6 (strict concurrency). Build: Swift Package Manager, Command Line
Tools only (no full Xcode). Platform: macOS 26 (SDK 26.2), Apple Silicon.

---

## 0. How to build and verify

```bash
swift build                 # expect: 0 errors, 0 warnings
swift run VoiceFlowTests    # expect: All 85 tests passed
./Scripts/build_app.sh release   # assembles + STABLE-signs dist/VoiceFlow.app
codesign -dvvv dist/VoiceFlow.app 2>&1 | grep Authority   # expect: Authority=VoiceFlow Local Signing (NOT ad-hoc)
```

There is no XCTest (CLT only); tests run as an executable target `VoiceFlowTests`
using a custom `VoiceFlowTestKit` harness. Runtime paths that need a mic, the
speech model, Apple Intelligence, or TCC permissions cannot be unit-tested and are
called out as "manual" below.

---

## 1. What the app is

A native macOS menu-bar push-to-talk dictation app. Hold a global hotkey (default
left Option), speak, release; the app transcribes on-device and inserts the text
into the focused app. Personal, macOS-only, fully on-device, no account, no cloud.

**Hard safety rules (must always hold):**
- **Never auto-send / never press Return.** No synthesized Return/Enter ever.
- **Never insert into a secure (password) field.** Copy to clipboard instead.
- **Never insert into the wrong app.** If the frontmost app changed between record
  start and insertion, copy to clipboard instead of inserting.
- **Never lose the user's words.** Every transcript is written to history and the
  clipboard even if insertion fails.

---

## 2. Architecture (seams)

Protocol-seamed. Core logic in `VoiceFlowCore` (pure, tested); platform code in
`VoiceFlowApp`. Key seams: `AudioRecording`, `Transcribing`, `CleanupProviding`,
`TextInserting`, `ActiveAppProviding`, `HotkeyManaging`, `HistoryStoring`,
`SecureStoring`. Orchestrated by the `DictationController` actor.

---

## 3. What changed this session (audit targets)

### 3.1 Transcription engine → Apple SpeechAnalyzer (macOS 26)
File: `Sources/VoiceFlowApp/Platform/SpeechAnalyzerDictation.swift`
- Replaces legacy streaming `SFSpeechRecognizer` with **record-to-file → batch
  transcribe with full context**. Captures mic audio to a temp `.caf` while the key
  is held; on release, `SpeechAnalyzer.analyzeSequence(from:)` over the whole file.
- **Verify:**
  - Only **final** results are accumulated: transcriber built with empty
    `reportingOptions` (no volatile), and results filtered `where result.isFinal`.
    Confirm no interim/volatile text can reach the output.
  - Finalization order: `analyzeSequence(from:)` → `finalize(through: lastTime)` →
    `finalizeAndFinishThroughEndOfInput()`. Confirm the results task cannot hang or
    miss segments (it is started before analysis; the stream ends after finalize).
  - `contextualStrings` (user vocabulary) is applied via `AnalysisContext` +
    `analyzer.setContext` before analysis. Confirm it is actually used (it was
    previously declared but dropped — a regression that is now fixed).
  - Locale is resolved via `SpeechTranscriber.supportedLocale(equivalentTo:)` from
    the `languageCode` argument; `ensureModelInstalled` compares full `identifier`
    (region-aware) so en-US is not satisfied by en-GB.
  - Temp file is always removed (`defer` in `transcribe`). Confirm no temp-file leak
    on the throw paths.
  - Concurrency: capture runs on the main thread (`onMain`); buffers written under
    an `NSLock` in the tap; no lock held across an `await`. Confirm Swift-6 safety.
  - Availability: the class is `@available(macOS 26.0, *)`; the coordinator selects
    it only under `#available` + `SpeechTranscriber.isAvailable`, else
    `LiveSpeechDictation` (legacy). Confirm no macOS-26 symbol is referenced outside
    an availability guard.

### 3.2 Cleanup engine → Apple Foundation Models, on-device (no API key)
File: `Sources/VoiceFlowApp/Platform/FoundationModelsCleanupProvider.swift`
- Uses `LanguageModelSession.respond(to:options:)` (Apple Intelligence, on-device)
  to fix grammar/punctuation/spacing without a key or network.
- **Verify:**
  - Deterministic + conservative: `GenerationOptions(sampling: .greedy,
    temperature: 0, maximumResponseTokens: …)`. Confirm it edits, not paraphrases.
  - **Anti-hallucination guard:** rejects output whose word count balloons
    (`> inWords*2`) or is gutted (`outWords*3 < inWords`) for inputs ≥ 3 words,
    throwing `cleanupProviderUnavailable` so the pipeline falls back to the
    deterministic result. Confirm the guard cannot pass through a meaning-changing
    rewrite, and that short inputs aren't over-rejected.
  - Availability: guarded by `SystemLanguageModel.default.isAvailable`; falls back
    when Apple Intelligence is off. Confirm graceful fallback.
- `CleanupPipeline` (`Sources/VoiceFlowCore/Cleanup/CleanupPipeline.swift`): rule
  engine always runs; LLM stage optional and best-effort; `cleanupProviderUnavailable`
  is a **silent** fallback; returns the **trimmed** refined text. Confirm no failure
  path blocks dictation and no untrimmed text escapes.

### 3.3 Deterministic cleanup correctness (Phase 0)
File: `Sources/VoiceFlowCore/Cleanup/TextNormalizer.swift`
- **Verify these are actually fixed** (golden tests in `CleanupTests.swift`):
  - `applySpokenPunctuation` is word-boundary anchored: "run the command" must NOT
    become "run the,nd"; "the periodic table" must not split. (Regex
    `(?<![A-Za-z0-9])…(?![A-Za-z0-9])`, symbol inserted via `escapedTemplate`.)
  - `capitalizeSentences` ignores decimals ("3.14") and single-letter initialisms
    ("U.S.", "e.g.") as sentence ends.
  - `fillerWords` no longer contains "you know" / "i mean" (deleting them changed
    meaning). Leading orphaned punctuation is stripped after filler removal.
- **Adversarial cases to try:** "e.g.", "i.e.", "3.14", "U.S.", "command", "colony",
  "periodic", "semicolonial", "Do you know", "I mean it", "um, hello".

### 3.4 Insertion (unchanged logic, confirm safety)
File: `Sources/VoiceFlowApp/Platform/AccessibilityTextInserter.swift`
- Wispr's method: set clipboard → synthesize ⌘V into the focused field → restore the
  previous clipboard after a delay. A Unicode-typing fallback exists (`typeAtCursor`)
  and converts newlines to spaces.
- **Verify the safety invariants hold:**
  - No path synthesizes Return/Enter. The typing fallback maps `\n`/`\r` → space.
  - `focusedFieldIsSecure()` is re-checked immediately before any paste/type/AX-set
    (TOCTOU closed); secure field ⇒ copy-only.
  - Destination change ⇒ copy-only: see `DestinationGuard.makePlan` in
    `Sources/VoiceFlowCore/Destination/DestinationGuard.swift` and
    `DestinationSnapshot.matches` (matches on bundle identifier).
  - `prepareForInsertion` activates the captured destination app before pasting.

### 3.5 Stable code-signing (the root cause of "inserts nothing")
File: `Scripts/build_app.sh`
- **Root cause fixed:** the signing keychain auto-locks, and `find-identity` ran
  *before* the unlock, silently falling back to ad-hoc signing → a new code identity
  every rebuild → macOS invalidated Accessibility/Input-Monitoring each reinstall →
  synthetic ⌘V posted but did nothing.
- **Verify:** the script now `security unlock-keychain` **before** the identity
  check; a build signs with "VoiceFlow Local Signing"; the designated requirement is
  cert-based (`certificate leaf = H"…"`) and therefore constant across rebuilds, so
  TCC grants persist. Confirm `dist/VoiceFlow.app` is NOT ad-hoc.

---

## 4. Specific claims to confirm or refute

1. No volatile/interim transcription text can reach the inserted output. (3.1)
2. The full transcript is deterministic and complete for a given recording — no race
   drops early segments. (3.1)
3. User vocabulary measurably biases recognition (contextualStrings wired). (3.1)
4. On-device cleanup can never change meaning: the guard + greedy sampling + fallback
   guarantee the worst case is the deterministic rule result. (3.2)
5. No cleanup or insertion failure path blocks or loses a dictation. (3.2, 3.4)
6. The four hard safety rules in §1 hold on every code path. (3.4)
7. Rebuilding + reinstalling does NOT reset macOS permissions (stable signing). (3.5)
8. 0 warnings under Swift 6 strict concurrency; 85 tests pass. (§0)

## 5. Known constraints (not defects)
- Requires macOS 26 for the SpeechAnalyzer engine and Foundation Models cleanup;
  older macOS falls back to legacy streaming + rule-based cleanup.
- On-device cleanup requires Apple Intelligence enabled by the user.
- Self-signed (not notarized); Gatekeeper warns on first open — expected for a
  personal, locally-built app.
- Real transcription accuracy is validated manually — see `docs/ACCURACY_BENCHMARK.md`.

## 6. Requested output from the reviewer
For each item in §4: CONFIRMED / DEFECT (with file:line + a concrete failing input)
/ CANNOT-VERIFY (why). Plus any additional correctness, concurrency, or safety
issues found in the files listed in §3.
