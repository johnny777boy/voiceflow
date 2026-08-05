# VoiceFlow Verbatim-Fidelity Fix Plan

**Date:** 2026-08-05
**Goal:** Match Wispr Flow — ~99% same-as-spoken, no dropped words, no missing spaces, consistent run-to-run.
**Bar:** verbatim fidelity over polish. Every fix below either recovers spoken audio, stops the pipeline from mutating the user's words, or removes run-to-run randomness.

The gap has four root causes, in impact order:

1. **Audio capture clips both ends of every utterance** (leading + trailing words lost). Fresh `AVAudioEngine` per keypress with no pre-roll and no tail drain. This is the single largest verbatim failure.
2. **The default cleanup prompt says "Rewrite"** — it licenses the on-device model to paraphrase, re-voice, and merge sentences, which the meaning-guard happily accepts.
3. **Spacing seams after punctuation are never repaired** — glue like `done.Then` survives, and a repeat-collapse rule actively glues words.
4. **Availability + model state is frozen at launch and re-sampled on the hot path** — same dictation yields different output depending on launch timing, thermal state, and which path silently ran.

All file paths are absolute under the worktree root
`/Users/yoni/Documents/projects/VoiceFlow/.worktrees/feature-system-dictation-daily-use/`.

---

## TOP 3 — DO NOW (highest impact-per-effort)

These three are small, low-risk, and each directly recovers verbatim content the app is losing today. Ship them first, verify with the protocol at the bottom, then proceed.

### DO-NOW #1 — Add a trailing drain + shrink the tap buffer (recovers the dropped LAST word)

**File:** `Sources/VoiceFlowApp/Platform/SpeechAnalyzerDictation.swift`
**Where:** `stopRecordingImpl` (lines 90–99) and the tap install (line 74).

**Problem.** On key-release, `removeTap` (line 92) stops buffer delivery *immediately* and `audioFile = nil` (line 95) closes the file *immediately*. The tap only delivers in 4096-frame chunks (~85 ms at 48 kHz), so the last partial chunk — routinely the tail of the final word — is never written. Users release the key as they finish the last syllable, so this loss lands squarely on the final word every time.

**Change.** (a) Shrink the tap buffer from `4096` to `1024` (~21 ms) so the worst-case undelivered tail is 4× smaller. (b) On stop, keep the tap live for a short drain window, then tear down engine-first, tap-second, file-last.

Line 74 — buffer size:
```swift
input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
```

Replace the body of `stopRecordingImpl` (lines 90–99) with a drained teardown:
```swift
private func stopRecordingImpl() throws -> AudioCapture {
    guard isRecording else { return AudioCapture(samples: [], sampleRate: 16_000, duration: 0) }
    isRecording = false
    levelHandler?(0)
    let engine = self.engine
    // Drain: let the hardware flush its final partial buffer(s) before teardown.
    // ~180 ms comfortably covers one 1024-frame chunk plus HAL latency.
    let deadline = DispatchTime.now() + .milliseconds(180)
    DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
        guard let self else { return }
        engine?.stop()                              // halt graph; let in-flight callbacks finish
        engine?.inputNode.removeTap(onBus: 0)       // then stop new delivery
        self.engine = nil
        self.lock.lock(); self.audioFile = nil; self.lock.unlock()   // close file LAST
    }
    return AudioCapture(samples: [], sampleRate: 16_000, duration: 0)
}
```

**Caller note.** `transcribe(...)` reads the file via `takeFileURL()`. Because teardown is now deferred ~180 ms, the controller must not call `transcribe` until the file is closed. Sequence the release path in `DictationController` (hot path ~lines 80–103) so `transcribe` runs after the drain completes — e.g. have `stopRecording` return only once the async teardown block has closed the file (await a continuation), or move the `transcribe` kickoff into the completion of the drain block. Do not read the `.caf` while it is still open.

**Why it closes the gap.** Order (stop → removeTap → close) plus a drain window guarantees the final partial buffer is delivered and written. Smaller buffers cap the residual loss even if the window is ever skipped. This is the change most likely to recover the dropped last word.

**Expected impact.** Eliminates trailing-word loss on the majority of utterances. High impact, ~20 lines, isolated.

---

### DO-NOW #2 — Stop the default prompt from rewriting the user's words

**File:** `Sources/VoiceFlowCore/Cleanup/CleanupPromptBuilder.swift`
**Where:** base `lines` (line 12) and the `.cleanWriting` case (line 18).

**Problem.** The shipped default mode (`.cleanWriting`) opens with *"Rewrite the transcript... fix... word choice... so it reads as if written by a fluent writer."* That is explicit license to paraphrase, swap synonyms, reorder clauses, and merge sentences. `CleanupGuard.preservesMeaning` only checks length/negation/number/30%-overlap, so a fluent re-voicing passes. Nothing in the system protects the user's actual words — this is the biggest verbatim risk in the cleanup stage.

**Change.** Replace the base contract line 12:
```swift
"You are an EDITOR, not a rewriter. Preserve the speaker's exact words and phrasing.",
"Keep every content word the speaker said. Do not substitute synonyms, do not reword phrases, do not reorder clauses, and do not merge or split the speaker's sentences unless a sentence is grammatically broken.",
"Your ONLY allowed changes are: fix punctuation and capitalization, correct obvious grammar (agreement, tense, articles/prepositions), and remove filler words ('um', 'uh', 'like'), false starts, and immediate self-corrections.",
"When in doubt, leave the text as spoken. Change as few words as possible.",
"Do not add new content, opinions, or facts."
```

Replace the `.cleanWriting` case at line 18:
```swift
case .cleanWriting:
    lines.append("General prose. Fix grammar, verb tenses, punctuation, and capitalization — including errors from a non-native or imperfect speaker — while keeping the speaker's own words and sentence structure. Remove filler words, false starts, and self-corrections. Do NOT paraphrase, upgrade vocabulary, or restyle phrasing that is already grammatical.")
```

**Why it closes the gap.** The verbatim outcome depends entirely on the prompt (the guard leaves paraphrase open). Naming synonym-swap, reordering, and sentence-merging as *forbidden* is what actually holds the model to the user's words. Non-native grammar correction — a fix the user does want — is preserved.

**Expected impact.** Largest single reduction in "it changed my wording." Zero code risk (prompt-only; only constrains the model further). ~6 lines.

---

### DO-NOW #3 — Repair spaces glued after punctuation; stop the collapse rule from gluing words

**File:** `Sources/VoiceFlowCore/Cleanup/TextNormalizer.swift`
**Where:** `tidyProse`, between the `" " + p` loop (ends line 111) and `normalizeWhitespace` (line 112); collapse rules at lines 104–106.

**Problem.** `tidyProse` strips the space *before* punctuation but has **no rule to add a space *after*** it, so LLM/transcriber seams like `done.Then next` and `yes!no way` survive untouched. Worse, the repeat-collapse rules (`\.{2,}`→`.`, `\?{2,}`→`?`, `!{2,}`→`!`) drop the following space, actively gluing `no...seriously`→`no.seriously`.

**Change.** Insert two guarded repair passes after the `" " + p` loop (before line 112):
```swift
for p in [".", ",", "?", "!", ":", ";"] {
    t = t.replacingOccurrences(of: " " + p, with: p)
}
// Repair words glued to the previous token's punctuation (LLM seams, collapsed runs).
// Period restricted to a sentence boundary (lowercase '.' UPPERCASE) so "Next.js",
// "example.com", "3.14", "U.S.", "file.name" are never split.
t = t.replacingOccurrences(of: "([a-z])\\.([A-Z])", with: "$1. $2",
                           options: .regularExpression)
// ? ! , ; : never appear inside real tokens between two letters.
t = t.replacingOccurrences(of: "([A-Za-z])([?!,;:])([A-Za-z])", with: "$1$2 $3",
                           options: .regularExpression)
t = normalizeWhitespace(t)
return capitalizeSentences(t)
```

**Why it closes the gap.** These are the only two mechanisms that produce "wordword" in the pipeline; the segment join (`SpeechAnalyzerDictation.swift:146`, `pieces.joined(separator: " ")`) always inserts a space and is *not* a source (cleared). The period rule is boundary-restricted so real dotted tokens are protected. Verified against `Next.js`, `example.com`, `3.14`, `U.S.`, `3:2`, `9:30`, `file.name` — all unchanged.

**Expected impact.** Removes the missing-space class from all prose/email output. ~8 lines. Residual: `no...seriously` (both neighbors lowercase) still collapses to `no.seriously` — acceptable, indistinguishable from a domain.

---

## THE REST — ranked by impact-per-effort

### 4. Warm-engine pre-roll ring buffer (recovers the dropped FIRST word)

**File:** `Sources/VoiceFlowApp/Platform/SpeechAnalyzerDictation.swift` — `startRecordingImpl` (lines 51–86).

**Problem.** A brand-new `AVAudioEngine` is built and `start()`ed synchronously on the keypress (`DictationController.beginRecording`). The input HAL warms up over ~50–300 ms; the first tap buffers are delayed or silent, and any speech before delivery is gone. There is no pre-roll, so the first syllable is clipped. Wispr masks this with an always-running capture graph.

**Change.** Build the engine and install the tap **once** (at app launch / when the hotkey arms), keep it running, and have the tap always write into a small circular buffer holding the last ~300–500 ms of float frames. On keypress, open the `AVAudioFile`, flush the ring buffer's contents into it first, then continue appending live buffers. Rebuild only on device/route change.

**Why after the top 3.** Bigger structural change (engine lifecycle moves out of the per-utterance path) than the trailing-drain fix, and the leading clip is often shorter than the trailing clip in practice. But it is the matching bookend — do it right after DO-NOW #1 to close both ends.

**Expected impact.** Eliminates leading-word loss; removes per-utterance `engine.start()` latency; structurally matches Wispr. Larger effort (~40–60 lines + lifecycle wiring).

### 5. Make the results/finalize path exception-safe; handle `analyzeSequence == nil`

**File:** `Sources/VoiceFlowApp/Platform/SpeechAnalyzerDictation.swift` — lines 140–158.

**Problem.** If any `finalize*` call (lines 150–153) throws, control jumps to `defer` and `resultsTask` (line 155) is never awaited or cancelled — the task leaks and the user sees a throw even when partial finals exist. When `analyzeSequence` returns `nil` (very short/silent clip), `finalize(through:)` is skipped and whether any `isFinal` segment emits is timing-dependent → intermittent `emptyTranscript` on near-identical short taps.

**Change.**
```swift
defer { resultsTask.cancel() }
let audioFile = try AVAudioFile(forReading: url)
guard let lastTime = try await analyzer.analyzeSequence(from: audioFile) else {
    throw VoiceFlowError.emptyTranscript   // clear "no speech", don't fall through
}
try await analyzer.finalize(through: lastTime)
try await analyzer.finalizeAndFinishThroughEndOfInput()
let text = (try? await resultsTask.value) ?? ""   // degrade to partial text on finalize error
```
Wrap so a `finalize` error still reads whatever finals arrived instead of yielding no text.

**Expected impact.** Removes a class of "sometimes empty" short-utterance flakes and one dropped-tail race. Medium effort.

### 6. Stop freezing `useLLM`/engine availability at launch

**File:** `Sources/VoiceFlowApp/AppCoordinator.swift` — lines 64, 81 (init at 42–100).

**Problem.** `FoundationModelsCleanupProvider.isAvailable` and `SpeechTranscriber.isAvailable` are sampled once in `init()`. On macOS 26 these are moving targets (false while Apple Intelligence downloads/updates or under thermal/memory pressure). App launched too early → cleanup silently stays rule-based for the whole session; relaunch later → it works. Pure launch-timing luck.

**Change.** Do not gate `useLLM` on the static check. Pass `useLLM = true` whenever `#available(macOS 26.0, *)` and let the provider's own per-call `isAvailable` (`FoundationModelsCleanupProvider.swift:18`) decide each utterance — it already throws `cleanupProviderUnavailable` and the pipeline falls back gracefully, but now recovers automatically the moment the model is ready. Log the unavailable→available transition.

**Expected impact.** Removes the single largest "relaunch and it works" consistency class. Low effort.

### 7. Warm up + reuse the SpeechAnalyzer session and LanguageModelSession

**Files:** `SpeechAnalyzerDictation.swift` (transcriber/analyzer built fresh per utterance, lines 121–127; `ensureModelInstalled` on the hot path, line 116), `FoundationModelsCleanupProvider.swift` (fresh `LanguageModelSession` per call, line 23).

**Problem.** First transcription/cleanup of a session pays model-load cost inside the key-held→release path, right where the finalize race is tightest → cold "slow and truncated" vs warm "fast and correct." First-run asset download (lines 165–172) runs synchronously in `transcribe`, with `reserve` result discarded (`try?`, line 168) and no retry/backoff on `downloadAndInstall` (line 172).

**Change.** Add `warmUp()` on `SpeechAnalyzerDictation` that resolves locale, runs `ensureModelInstalled`, and constructs+retains a transcriber/analyzer; call it from `AppCoordinator.start()` and `DictationController.beginRecording()`, not lazily in `transcribe`. Gate the mic UI on "model ready." Wrap `downloadAndInstall()` in bounded retry (3×, backoff) and re-read `installedLocales` after success; check the `reserve` result instead of discarding. Create one long-lived `LanguageModelSession`, `prewarm()` it at launch, reuse across utterances.

**Expected impact.** Removes cold-start truncation and first-run stalls; big consistency win. Medium-large effort.

### 8. Split the guard-rejection error from "unavailable"; surface the delivered path

**Files:** `FoundationModelsCleanupProvider.swift:39`, `CleanupPipeline.swift:33`, `CleanupGuard.swift`.

**Problem.** The guard reuses `cleanupProviderUnavailable` for both "model absent" (line 18) and "model produced a meaning-changing edit" (line 39). The pipeline can't distinguish them, so borderline outputs that land just inside the thresholds one run and just outside the next are logged identically as "unavailable" — the user gets polished prose sometimes and raw output other times with no signal.

**Change.** Introduce a distinct `cleanupRejectedByGuard` error at line 39; log it separately at `CleanupPipeline.swift:33-37`. Optionally retry `session.respond` once on guard rejection (a temp-0 re-run often clears a borderline case). Record the delivered path (AI vs rule) in the history/overlay so run-to-run differences are explainable rather than random-feeling.

**Expected impact.** Makes the biggest user-visible intermittency measurable and reduces borderline flips. Low-medium effort.

### 9. Stop `try?`-swallowing `setContext`

**File:** `SpeechAnalyzerDictation.swift:135`.

**Problem.** Contextual biasing (user names/jargon) is set with `try?`. On failure it silently vanishes for that utterance → the same word transcribes correctly on one run and as a homophone on the next, with no log.

**Change.** Set context on the retained/warmed transcriber (from fix #7) *before* the analyzer starts; log on failure instead of swallowing; retry once if context is essential.

**Expected impact.** Reduces run-to-run accuracy variance on names/jargon. Low effort (pairs with #7).

### 10. Cleanup robustness / structural-expansion guards (defense-in-depth)

**Files:** `FoundationModelsCleanupProvider.swift:29`, `CleanupGuard.swift:~39`, `AppSettings.swift:36`.

- **Token cap:** `maximumResponseTokens: max(256, rawText.count)` mixes chars and tokens, permitting ~4× expansion. Cap nearer the input estimate, e.g. `max(64, rawText.count / 3 + 32)`, so ballooning is structurally impossible.
- **Exact-word retention floor (optional):** in `CleanupGuard.preservesMeaning`, after the meaning checks, require a high fraction (~0.7) of the original's significant words to appear verbatim for short-to-medium input — a backstop against paraphrase drift. Set conservatively so genuine non-native grammar fixes still pass.
- **Lighter default (optional):** consider `cleanupStrength = .light` as the shipped default (`AppSettings.swift:36`) to match the ~99% bar. **Verify first** that the rule-based `.light` path (`RuleBasedCleanup.swift`, used when Apple Intelligence is unavailable) still capitalizes sentences and adds terminal punctuation — today `.light` means whitespace-only there, so the fallback would regress.

**Expected impact.** Prevents structural expansion and adds a paraphrase backstop. Low effort; the DO-NOW #2 prompt change is the load-bearing lever, these are secondary.

### 11. Move file writes off the real-time render thread

**File:** `SpeechAnalyzerDictation.swift` — tap closure (lines 74–78).

**Problem.** `try? self.audioFile?.write(from: buffer)` does CAF encoding + disk I/O on the audio render thread, under `lock` (also taken on main during teardown) → two-way priority inversion and dropped input buffers under disk stall. `try?` swallows write failures, so a full/failed disk silently yields `emptyTranscript` with no diagnostic.

**Change.** In the tap, copy/retain the `AVAudioPCMBuffer` and enqueue to a dedicated serial `DispatchQueue`; run `write(from:)` there. Drop the `NSLock` from the hot path (the serial queue serializes open/write/close). Log write failures instead of discarding. Optionally downmix to mono in the off-thread writer to halve I/O.

**Expected impact.** Robustness against glitches under load + observability. Medium effort; do when touching the capture path for fix #4.

### 12. Simplify the double-finalize (cleanup, verify no regression)

**File:** `SpeechAnalyzerDictation.swift` — lines 149–153.

`finalizeAndFinishThroughEndOfInput()` already finalizes through end of input, so the explicit `finalize(through: lastTime)` is redundant. Not a confirmed word-drop (dedup by `isFinal`), but simplify to just `finalizeAndFinishThroughEndOfInput()` after `analyzeSequence` **once capture is verified verbatim**, and confirm final segments still cover the full audio. Lowest priority.

---

## Verbatim-fidelity test protocol

Run after each DO-NOW fix and before merge. The point is to prove where content is lost — capture vs. analyzer vs. cleanup — rather than guess.

### A. Boundary capture test (isolates capture vs. analyzer)
1. Temporarily disable the `.caf` cleanup (`removeItem` at `SpeechAnalyzerDictation.swift:110`) so the raw file survives.
2. Dictate a phrase that **starts and ends on hard consonants**: e.g. *"Kevin packed six boxes quick."* Start speaking slightly *before* pressing and release the key *as* you finish the last syllable (the natural failure timing).
3. Open the `.caf` waveform (Audacity/QuickTime) and inspect head and tail:
   - First/last phoneme **missing from the file** → capture bug (fixes #1, #4, #11).
   - Present in the file but **missing from the transcript** → analyzer/finalize (fixes #5, #12).
4. Log `audioFile.length` frames vs. the `recordStartTime`→release wall-clock (`DictationController` ~lines 69/86) to quantify head/tail ms lost. Target: <50 ms clipped at each end.

### B. Verbatim word-for-word set (measures fidelity end-to-end)
Fixed script of 20 utterances covering: leading/trailing hard consonants; fast starts; names & jargon (contextual strings); numbers and negations; sentences that end abruptly. Dictate each 3×.
- **Metric:** word error rate vs. the exact spoken script (substitutions + deletions + insertions). Target ≤1% (≈ Wispr).
- **Pass criteria:** no dropped first/last word across the 3 repeats; no synonym substitutions or reworded phrases (fix #2); numbers and negations preserved verbatim.

### C. Spacing seam set (validates fix #3, guards regressions)
Assert exact output for glue and protected tokens:
- Repairs: `done.Then next`→`done. Then next`, `yes!no way`→`yes! no way`, `really?maybe not`→`really? maybe not`, `wait,then go`→`wait, then go`, `he said:hello`→`he said: hello`.
- Protected (must stay unchanged): `Next.js`, `example.com`, `3.14`, `the U.S. Army`, `3:2`, `9:30 am`, `file.name`, `path.to.thing`.
- Known residual (accept): `no...seriously`→`no.seriously`.

### D. Consistency test (validates #5, #6, #7, #8)
Dictate the **same** utterance 10× in one session and 5× immediately after a cold launch.
- Output text identical across all runs (allowing only the documented residual).
- Every run reports the **same delivered path** (AI vs rule) — surfaced via fix #8. A path flip on identical input is a failure.
- No `emptyTranscript` on any short-but-valid tap.

### E. Regression gate
Existing `CleanupPromptBuilder` / `TextNormalizer` / `CleanupGuard` unit tests must pass. Add unit cases for the fix #3 spacing pairs (C) and a prompt-snapshot test asserting the word "Rewrite" no longer appears in the `.cleanWriting` prompt (fix #2).
