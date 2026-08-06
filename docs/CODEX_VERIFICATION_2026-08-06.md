# VoiceFlow — Codex Verification (2026-08-06, full current state)

Independent verification of everything since the last round. Self-contained.
Repo `github.com/johnny777boy/voiceflow` · branch `main` · HEAD `a59b475`.
Build: Swift 6, SPM, Command Line Tools only, macOS 26 (SDK 26.2), Apple Silicon.
Read the prior package `docs/CODEX_VERIFICATION_2026-08-05.md` for the base
architecture and the four hard safety rules — those still apply and must still hold.

## 0. Build & verify
```bash
swift build --disable-sandbox        # expect 0 errors, 0 warnings
swift run --disable-sandbox VoiceFlowTests   # expect: All 92 tests passed
```

## 1. New / changed areas to audit (since 2026-08-05)

### 1.1 Warm mic + pre-roll (leading-word fix) — MED risk (audio path)
`Sources/VoiceFlowApp/Platform/SpeechAnalyzerDictation.swift`
- A long-lived `AVAudioEngine` is kept warm (`prewarm()` / `startEngineIfNeeded()`),
  with a permanent tap that fills a ~0.5s pre-roll ring buffer while idle
  (`handleTap`). On record, the pre-roll is written to the file first, then live
  audio; on stop, a ~180ms drain runs before teardown, and the engine STAYS warm.
- **Verify:** no audio is dropped or double-written; `recording` gates file writes;
  the ring buffer is trimmed to the frame limit; the deep `copy(_)` is correct for
  float and int16; `prewarm()` is only invoked with mic permission
  (`AppCoordinator.refreshPermissionStatus`); NSLock is never held across an await;
  no retain cycle keeps the engine alive incorrectly; the temp `.caf` is always
  removed. Flag any path that could clip or lose audio, or leave the mic on when it
  shouldn't.

### 1.2 N-best vocabulary re-ranking — LOW risk (post-decode)
`SpeechAnalyzerDictation.swift` (`bestCandidate`, `vocabTokens`, results loop)
- Transcriber now sets `reportingOptions:[.alternativeTranscriptions]`,
  `attributeOptions:[.transcriptionConfidence]` (still NO `.volatileResults`).
- Each final segment keeps top-1 unless an alternative has STRICTLY more user-vocab
  hits (ties → higher confidence).
- **Verify the key safety claim:** when the vocab set is empty or no candidate
  contains a vocab token (the common case), the output is byte-identical to top-1 —
  i.e. this can NEVER change generic transcription. Look for any input where it could
  pick a worse alternative.

### 1.3 Cleanup availability re-checked per call — LOW risk
`Sources/VoiceFlowApp/AppCoordinator.swift` (~line 64)
- On macOS 26 the app ALWAYS uses `FoundationModelsCleanupProvider` (no longer gated
  on `isAvailable` at init). The provider checks `SystemLanguageModel.default.isAvailable`
  on every `clean()` and throws `cleanupProviderUnavailable` (→ rule-based fallback)
  when not ready.
- **Verify:** cleanup can never crash or block if Apple Intelligence is unavailable;
  it silently degrades to the deterministic result; no repeated expensive setup per call.

### 1.4 Automatic best-fit mode — LOW risk
`Sources/VoiceFlowCore/Models/AppSettings.swift` (`mode(forBundleIdentifier:)`, `autoMode`)
- Resolution order: explicit per-app rule > `autoMode(bundleID)` > global default.
  `autoMode`: code editors/terminals → `.claudeCode`; mail → `.email`; everything else
  → `.cleanWriting`.
- **Verify:** a code/terminal bundle never gets prose punctuation forced into commands;
  a normal app always gets Clean Writing (so punctuation is consistent regardless of the
  stored `defaultMode`); the string `contains` heuristics can't misclassify (e.g. an app
  with "mail" in an unrelated bundle id). Covered by a unit test in `CleanupTests.swift`.

### 1.5 Meaning-preserving cleanup guard — LOW risk (already reviewed, re-confirm)
`Sources/VoiceFlowCore/Cleanup/CleanupGuard.swift`
- `preservesMeaning` rejects on: length balloon/gut, negation-count change, changed
  number, or <30% significant-word overlap. Used by `FoundationModelsCleanupProvider`.
- **Verify:** the negation counter handles whole words + `n't`; numbers subset check
  is correct; confirm the known limit (pure antonym swap with no negation/number
  change is NOT caught) and report any *new* dangerous class that slips through.

### 1.6 Deterministic formatting — LOW risk (re-confirm)
`Sources/VoiceFlowCore/Cleanup/TextNormalizer.swift`
- `tidyProse` now also INSERTS a missing space after glued punctuation while
  protecting `3.14`, `9:30`, `e.g.`, `example.com`, `Next.js`. Confirm no over-splitting.

## 2. Claims to confirm/refute (CONFIRMED / DEFECT file:line+input / CANNOT-VERIFY)
1. Re-ranking cannot change generic (no-vocab) transcription output. (1.2)
2. Warm-mic path never drops/duplicates audio and never holds a lock across await. (1.1)
3. Cleanup degrades silently to rule-based whenever the on-device model isn't ready. (1.3)
4. Auto-mode keeps code literal and gives every prose app Clean Writing; can't misclassify. (1.4)
5. The four hard safety rules (no auto-send, no secure-field insert, no wrong-app insert,
   never lose words) still hold across all changed paths.
6. 0 warnings; 92 tests pass.

## 3. Known constraints (not defects)
macOS 26 + Apple Intelligence required for the modern engine/cleanup (else legacy
fallbacks). Self-signed local build (Codex's sandbox build is ad-hoc — the stable
`VoiceFlow Local Signing` identity only exists on the owner's machine). Real
transcription accuracy is a live-mic measurement — see `docs/ACCURACY_BENCHMARK.md`
and `docs/AB_TEST_WISPR.md` (WER), not a static check.
