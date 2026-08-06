# VoiceFlow Transcription Accuracy — Prioritized Implementation Plan

Date: 2026-08-06
Goal: raise on-device transcription accuracy toward Wispr/Whisper parity, without regressing audio capture. The app has a history of audio-capture bugs, so anything touching the capture/tap/file path is flagged HIGH-RISK and must be tested with a live mic before merge.

Primary engine file (all line refs are to it unless noted):
`Sources/VoiceFlowApp/Platform/SpeechAnalyzerDictation.swift`

Context wiring file:
`Sources/VoiceFlowApp/AppCoordinator.swift`

Objective metric for every item: `Scripts/wer.py`. See "How to verify with wer.py" at the end for the standard harness; each item lists its specific check.

---

## Risk taxonomy used below

- **LOW** — isolated to `transcribe(...)` post-decode or to context assembly. Does NOT touch the mic/tap/file write path. Cannot regress recording.
- **MED** — changes what audio reaches the transcriber, or adds an analyzer module. Recording-to-file is unchanged but decode behavior changes.
- **HIGH** — rewrites the capture/tap/file-format path, OR swaps the transcriber model. Can regress recording or globally lower WER. **Live-mic test mandatory.**

---

## Ranked plan (impact-per-effort)

| # | Item | Impact | Effort | Risk | Touches capture? |
|---|------|--------|--------|------|------------------|
| 1 | Validate `contextualStrings` actually biases `SpeechTranscriber` (A/B) | Gates everything below | XS | LOW | No |
| 2 | Enable alternatives + confidence, conservative vocab re-rank | High (homophones/jargon) | S | LOW | No |
| 3 | Per-recording context enrichment (app + window title + recent transcripts) | High | M | LOW | No |
| 4 | Mic-selection guard + low-rate/Bluetooth warning log | Med (diagnoses "bad transcript") | XS | LOW | No |
| 5 | `SpeechDetector` (VAD) ahead of transcriber — kill phantom tokens | Med | S | **MED** | No (decode path) |
| 6 | Audio format normalization to `bestAvailableAudioFormat` (mono 16 kHz) | High | M | **HIGH** | **Yes** |
| 7 | `SFCustomLanguageModelData` custom LM + pronunciations (via `DictationTranscriber`) | High for names/jargon | L | **HIGH** | No (model swap) |
| 8 | Voice-processing IO (NS/AEC/AGC), off by default | Situational (noisy rooms) | M | **HIGH** | **Yes** |

---

# TOP 3 "DO NOW" (low-risk, highest impact-per-effort)

## 1. Validate that `contextualStrings` actually biases `SpeechTranscriber` — BLOCKING, zero code risk

**Why first.** The code sets `context.contextualStrings = [.general: terms]` (line 175) and the header comment calls it "the single highest-value accuracy fix." But whether `SpeechTranscriber` (as opposed to `DictationTranscriber`) actually honors contextual biasing is disputed in the developer community. Items 3 and 7 are built on this assumption. If it is silently ignored, that work must pivot to `DictationTranscriber`/custom LM or to the post-transcription vocabulary replacer. This is a 30-minute experiment that de-risks the whole roadmap.

**Change (temporary test harness, not shipped).** Add a deliberately unusual term that cannot be guessed acoustically to the vocabulary (e.g. a coined brand name like "Zworble"), then dictate a fixed sentence containing it twice: once with `contextualStrings` populated, once with `terms = []` forced empty at line 172.

**Expected accuracy impact.** None directly — this is measurement. It determines whether the ~100-term bias list is doing anything.

**Risk.** LOW. No shipped code change; you only temporarily force `terms = []` for the B run.

**Verify with wer.py.**
```
# Read the SAME reference sentence aloud both times.
# A run: contextualStrings populated (current code)
python3 Scripts/wer.py --ref "email zworble about the winawer variation" --hyp "<A output>"
# B run: force `let terms: [String] = []` at line 172, rebuild, same sentence
python3 Scripts/wer.py --ref "email zworble about the winawer variation" --hyp "<B output>"
```
If A's WER is materially lower than B's (the coined term transcribes correctly only in A), biasing works — proceed with items 3 and 7 as written. If A == B, biasing is ignored on `SpeechTranscriber`: escalate item 7 (DictationTranscriber path) and lean on the cleanup-stage vocabulary replacer instead.

---

## 2. Enable alternatives + confidence and add conservative vocab re-ranking — LOW risk, high value

**Why.** `SpeechTranscriber.Result.alternatives` is populated only when `.alternativeTranscriptions` is in `reportingOptions`. Current code passes `reportingOptions: []` (line 165), so the n-best list is discarded before it exists. Adding it, plus `.transcriptionConfidence`, lets us re-rank each final segment toward the user's known vocabulary — fixing exactly the homophone/jargon class ("Xcode" vs "ex code", "pill" vs "peel"). This is pure post-decode metadata; it never touches the recording path and, done conservatively (anchored on top-1, only overridden on a strict vocab win), it cannot degrade the common case.

**Change A — options (lines 162-167).**
```swift
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],                       // keep etiquetteReplacements OFF (would mask dictated profanity)
    reportingOptions: [.alternativeTranscriptions], // populate result.alternatives; still NO volatile results
    attributeOptions: [.transcriptionConfidence]    // per-run confidence for re-ranking + future gating
)
```
This preserves the deliberate "final segments only, no volatile" design (comment lines 159-161 stays true — `.volatileResults` remains omitted).

**Change B — conservative re-rank in the results loop (lines 181-188).**
```swift
let vocab = Self.vocabTokens(from: terms)               // built once, before the loop
let resultsTask = Task { () throws -> String in
    var pieces: [String] = []
    for try await result in transcriber.results where result.isFinal {
        let best = Self.bestCandidate(result, vocab: vocab)   // top-1 unless an alt clearly wins
        let piece = best.trimmingCharacters(in: .whitespacesAndNewlines)
        if !piece.isEmpty { pieces.append(piece) }
    }
    return pieces.joined(separator: " ")
}
```
Add helpers near the other statics (~line 217):
```swift
private static func vocabTokens(from terms: [String]) -> Set<String> {
    var set = Set<String>()
    for t in terms {
        for w in t.lowercased().split(where: { !$0.isLetter && !$0.isNumber }) where w.count > 1 {
            set.insert(String(w))
        }
    }
    return set
}

/// LIGHT re-rank: start from the model's top-1 and only switch to an alternative that
/// contains STRICTLY more of the user's vocabulary (ties broken by higher confidence).
/// When all candidates tie at 0 vocab hits (the common case) top-1 is kept unchanged.
private static func bestCandidate(_ result: SpeechTranscriber.Result, vocab: Set<String>) -> String {
    let top = result.text
    guard !vocab.isEmpty, !result.alternatives.isEmpty else { return String(top.characters) }
    func vocabHits(_ s: AttributedString) -> Int {
        var hits = 0
        for w in String(s.characters).lowercased().split(where: { !$0.isLetter && !$0.isNumber })
        where vocab.contains(String(w)) { hits += 1 }
        return hits
    }
    func avgConfidence(_ s: AttributedString) -> Double {
        var sum = 0.0, n = 0.0
        for run in s.runs { if let c = run.transcriptionConfidence { sum += c; n += 1 } }
        return n > 0 ? sum / n : 0
    }
    let topHits = vocabHits(top)
    var bestText = top, bestHits = topHits, bestConf = avgConfidence(top)
    for alt in result.alternatives {
        let h = vocabHits(alt)
        if h > bestHits || (h == bestHits && h > topHits && avgConfidence(alt) > bestConf) {
            bestText = alt; bestHits = h; bestConf = avgConfidence(alt)
        }
    }
    return String(bestText.characters)
}
```

**Expected accuracy impact.** Directly reduces substitution errors on vocabulary terms and homophones. On general text with no vocab hits, identical to today (top-1 preserved by construction). Bounded upside but zero downside.

**Risk.** LOW. Isolated to `transcribe(...)` after decode. No capture-path change. The `.alternativeTranscriptions` / `.transcriptionConfidence` options do not change which model asset downloads, so `ensureModelInstalled` (lines 205-215) needs no change.

**Verify with wer.py.** Build a 15-utterance set seeded with vocabulary terms and homophones. Score before vs after Change B on the SAME recorded outputs (transcribe the same `.caf` twice by keeping a copy). Expect substitutions (the `[ref→hyp]` markers in wer.py's diff) on vocab terms to drop; total WER should be equal-or-lower, never higher. Log the per-run confidence values first to calibrate any future gating (Change C, deferred).

---

## 3. Per-recording context enrichment — LOW risk, high value (gated on Item 1 passing)

**Why.** Today `live.contextualStrings` is assigned only at launch (`AppCoordinator.swift:115`) and on settings change (`:323`) — it is static and can carry only saved vocabulary. Meanwhile `DictationController.beginRecording()` already captures a `DestinationSnapshot` (frontmost app name + window title + focused-element role) and throws it away for recognition purposes. Window titles are dense with the proper nouns you are about to dictate (channel names, filenames, PR titles, recipients). Because `self.contextualStrings` is read late (line 172) at stop-time, assigning `live.contextualStrings` just before `controller.beginRecording()` already flows through with no protocol change.

**Change — assemble context per recording.** In `AppCoordinator.beginRecordingTransition` (around `AppCoordinator.swift:261`, before `try await controller.beginRecording()`):
```swift
let snapshot = WorkspaceActiveAppProvider().captureSnapshot()   // ideally SHARE the one the controller takes
live.contextualStrings = contextualStrings(from: settings, destination: snapshot, history: recentRecords)
```
Extend the assembler (`AppCoordinator.swift:312`) into a priority-ordered, case-insensitively-deduped merge, capped at 100 short phrases:
1. Enabled vocabulary (both `written` and `spoken`) — always.
2. `snapshot.appName` + proper-noun tokens from `snapshot.windowTitle` (split on separators; drop stopwords, short/numeric tokens; keep capitalized words; never pass the title whole).
3. Capitalized multi-word phrases from the last ~10 `recentRecords[].cleanText`.
4. (Later, opt-in) a curated names/brands list.

**Privacy guards (mandatory).**
- If `snapshot.isSecureInput` is true, suppress ALL dynamic context for that recording (window titles can be password-manager entries).
- Gate source 3 behind `settings.historyEnabled` / `privacyRedactionEnabled`.
- Build transiently at record-start; never persist app/window/history-derived strings.
- Tighten dedup to case-insensitive (current `Set` keeps both "GitHub" and "github").

**Expected accuracy impact.** High for proper nouns and in-context terms, which are the highest-error class in dictation. Self-reinforcing: terms you just dictated bias the next utterance.

**Risk.** LOW for recognition/recording — all changes are in `AppCoordinator`, none touch the tap/file path. The only real cost is one extra synchronous Accessibility round-trip per recording; avoid it by sharing the single snapshot the controller already captures (small refactor: have `beginRecording` accept an optional pre-captured snapshot). **Dependency:** only worthwhile if Item 1 proves `SpeechTranscriber` honors biasing; if not, this pivots to `DictationTranscriber`.

**Verify with wer.py.** Dictate the same reference sentence containing a window-title proper noun (e.g. open a doc titled "Winawer notes", dictate "add this to Winawer notes") with enrichment on vs off. Expect the proper noun to transcribe correctly only with enrichment; confirm total WER on generic sentences is unchanged (no false-positive substitutions from an over-stuffed list).

---

# Also low-risk, quick win (do alongside the top 3)

## 4. Mic-selection guard + low-rate/Bluetooth warning — XS effort, LOW risk

**Why.** `AVAudioEngine.inputNode` uses the system default input. On AirPods/Bluetooth, macOS routes through the SCO hands-free profile at 8–16 kHz with heavy telephony compression — a real accuracy hit that presents as "bad transcript / doesn't insert," which the project memory notes is usually environmental, not a code bug. Surfacing it turns a mystery into a diagnosis.

**Change.** At `startEngineIfNeeded` after line 70 (already logs rate/ch), add a warning when `fmt.sampleRate <= 16000` or the device name looks Bluetooth, and log the input device name. Keep the existing `channelCount == 0` guard (line 64).

**Expected impact.** Indirect — no WER change by itself, but prevents silent degradation and guides the user to the built-in/USB mic.

**Risk.** LOW (logging-only variant is effectively zero). If you go further and pin the device via `input.auAudioUnit.deviceID`, re-read `inputFormat` AFTER setting it (setting the device can momentarily yield a 0-channel/0-rate format — the existing guard catches it), which nudges this toward MED. Start with logging only.

**Verify with wer.py.** Record the same sentence on built-in mic vs Bluetooth; score both. Documents the delta and confirms the warning fires on the low-rate path.

---

# HIGH-RISK items — must be tested with a live mic before merge

## 5. `SpeechDetector` (VAD) ahead of the transcriber — MED risk (decode path, not capture)

**Why.** A VAD module in the same `SpeechAnalyzer` gates leading/trailing silence and room noise out of the audio the transcriber decodes, removing the input that seeds phantom tokens ("you", "thank you", repeated words) when the key is held over silence. It also shortens finalize. Recording-to-file is unchanged, so this is MED (decode behavior), not HIGH — but it can clip quiet opening words, so a live-mic check is required.

**Change (replace the single line 168).**
```swift
var modules: [any SpeechModule] = [transcriber]
let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false)
// WORKAROUND (macOS 26.0): SpeechDetector does not yet visibly conform to SpeechModule
// (Apple: fixed in the next Tahoe point update). Cast at runtime; fall back to
// transcriber-only if the conformance is absent, rather than failing to compile/crashing.
if let detectorModule = detector as? (any SpeechModule) {
    modules.insert(detectorModule, at: 0)     // detector first, transcriber second
} else {
    Log.transcription.notice("SA: SpeechDetector unavailable as module — transcribing without VAD")
}
let analyzer = SpeechAnalyzer(modules: modules)
```
Everything else (context block 172-177, results loop 181-188, finalize 191-194) is unchanged; we do NOT consume the detector's own stream (`reportResults: false`) — we only want its effect on the transcriber's input.

**Interaction with the pre-roll/drain (capture path — DO NOT rip out blind).** The ~0.5s pre-roll (line 117) and 0.18s trailing drain (line 131) exist to protect the first/last word against mic warm-up. Keep the pre-roll. The trailing drain can *likely* be shortened once VAD suppresses trailing silence — tune empirically, do not remove.

**Expected impact.** Fewer insertions (phantom tokens) — visible as `[+word]` markers disappearing in wer.py's diff — and equal-or-faster finalize.

**Risk.** MED. Live-mic checks required: (a) dictate a phrase then hold the key over ~2s of silence — confirm the trailing "you"/"thank you" is gone; (b) dictate a soft opening word ("So how come…") — confirm it is NOT clipped; if clipped, raise `sensitivityLevel` to `.high`. Verify the `as? (any SpeechModule)` cast succeeds on the build machine (a direct `[transcriber, detector]` literal will not compile on 26.0).

**Verify with wer.py.** Same recorded utterances, VAD off vs on. Insertions (I count) should drop; substitutions/deletions must not rise. Watch the "SA transcribed N chars" latency log (line 198) — finalize equal or faster.

---

## 6. Audio format normalization to `bestAvailableAudioFormat` (mono 16 kHz) — HIGH risk (rewrites capture write path)

**Why.** The tap format is the hardware default (`input.outputFormat(forBus: 0)`, line 67) — typically 48 kHz, possibly stereo — written verbatim to the `.caf` (line 108) and handed to the analyzer (lines 190-191), which resamples on every utterance. Feeding the recognizer its exact preferred format (mono 16 kHz Float32) removes a resample stage and channel ambiguity, and shrinks the temp file ~6× (a latency win for push-to-talk).

**Change.** Keep `tapFormat = input.outputFormat(forBus: 0)` for the tap (the tap must use the node's real format). Resolve `recordFormat = SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])` once, build ONE persistent `AVAudioConverter(from: tapFormat, to: recordFormat)`, open the file with `recordFormat.settings` (line 108), and run every buffer through that converter before `write(from:)` in BOTH `handleTap` (line 85) and the pre-roll writes (line 117).

**Expected impact.** Modest WER gain from deterministic mono downmix + exact-format match (Apple's API garbles input that differs from `bestAvailableAudioFormat`); meaningful latency gain from the smaller file.

**Risk.** HIGH — this is the capture/file path the app has bugged before. Regression flags:
- Use exactly ONE converter for the whole recording; a fresh converter per buffer resets resampler phase → clicks. `reset()` it in `startRecordingImpl`.
- Pre-roll (line 117) and live writes (line 85) MUST go through the SAME converter instance; never double-convert.
- `prerollFrameLimit` (line 69) is a frame count derived from the tap rate — keep the ring buffer measured in TAP-format frames and convert only at write time, so the two rates are never mixed.
- The conversion runs on the render thread (line 80-95, under the `NSLock`) — keep it allocation-free (reuse output buffers) or risk dropouts.
- Do not touch the `AudioCapture(sampleRate: 16_000)` sentinels (lines 127, 139) — they are empty because transcription reads the file, not `samples`.

**Live-mic test mandatory.** Record and play back the `.caf` (listen for clicks/dropouts), then transcribe. Test built-in mic AND a mic that reports stereo/odd rates.

**Verify with wer.py.** Same spoken sentences, old format vs normalized. WER equal-or-lower; specifically confirm no NEW deletions/garbling (the documented failure mode of a format mismatch). Also record the finalize-latency delta from the "SA transcribed N chars" log.

---

## 7. `SFCustomLanguageModelData` custom LM + X-SAMPA pronunciations — HIGH risk (transcriber MODEL swap)

**Why.** This is the only way to fix words Apple *hears wrong phonetically* (surnames, brands, jargon) — something `contextualStrings` can never do — plus weighted, in-context phrase biasing. But the custom-LM content hint (`.customizedLanguage(modelConfiguration:)`) exists ONLY on `DictationTranscriber`, not `SpeechTranscriber` (line 162). Attaching it therefore requires switching the transcriber module, which uses the system-dictation models — a different model whose WER on your utterances is unknown.

**Change (gated Path A).** Build the compiled model once (cached on disk by a hash of the vocab+pronunciations), and switch to `DictationTranscriber` ONLY when a custom model exists; otherwise keep today's `SpeechTranscriber` untouched. Add a new `CustomSpeechModel` builder type (`export` → `SFSpeechLanguageModel.prepareCustomLanguageModel` → attach via content hint), a `customPronunciations` field on the engine (~line 19), and compile it in a prewarm step (near `prewarm()` line 57), NEVER in the push-to-talk hot path. Add a parallel `AssetInventory.assetInstallationRequest(supporting: [dictationTranscriber])` alongside line 211. Factor the results loop (181-188) into a shared helper so both module paths reuse it.

**Expected impact.** High for persistent name/jargon mishearings (the pronunciation case). Weighted phrase counts beat flat `contextualStrings`.

**Risk.** HIGH — model-quality regression. `DictationTranscriber` ≠ `SpeechTranscriber`; it may be worse on general utterances. Compile latency (`prepareCustomLanguageModel`) is not instant — must be prewarmed/cached, never inline. The `weight` (0.0–1.0) over-biases if too high. X-SAMPA is locale-limited — filter every phoneme against `supportedPhonemes(locale:)` (unsupported symbols are silently dropped; log the diff).

**Live-mic test mandatory.** Benchmark WER of `DictationTranscriber` vs `SpeechTranscriber` on your real utterances BEFORE defaulting to it. Keep it gated ("only when custom terms exist") so users with no custom vocab keep today's quality.

**Verify with wer.py.** Two suites: (a) a general-speech suite scored on both transcribers to prove `DictationTranscriber` does not regress baseline WER; (b) a names/pronunciation suite (the misheard surnames/brands) to prove the custom LM fixes them. Ship only if (a) is within ~1–2 points and (b) improves.

---

## 8. Voice-processing IO (NS/AEC/AGC), off by default — HIGH risk (capture path + can lower WER)

**Why.** `input.setVoiceProcessingEnabled(true)` swaps in Apple's VoiceProcessingIO unit (noise suppression + echo cancellation + AGC) — helpful in noisy rooms. It is the only programmatic route to NS/AGC on macOS.

**Change.** Runtime-toggleable setting, DEFAULT OFF. In `startEngineIfNeeded` (59-78), before `prepare()`/tap install: `if enableVoiceProcessing { try? input.setVoiceProcessingEnabled(true) }`, optionally `input.isVoiceProcessingAGCEnabled = false`, then RE-READ the input format and build the converter (requires Item 6 first).

**Expected impact.** Can raise WER in noisy conditions — or LOWER it (over-suppression, musical-noise artifacts, AGC pumping on soft speech). The only lever here that can go either way.

**Risk.** HIGH:
- VP often changes the input node to 5–7 channels — you MUST have Item 6's converter first, or it regresses; a naive converter after VP is a known "outputs only silence" trap.
- VP builds an input+output aggregate and THROWS when devices don't match (AirPods mic + laptop speakers) — wrap in `try?` with fallback to plain capture; never let it crash the always-warm engine (`prewarm()` line 57).
- AGC ramps gain over the first ~200–500 ms, which can attenuate the exact opening word the pre-roll exists to save — disable AGC while keeping NS/AEC.

**Live-mic test mandatory.** A/B on real noisy-room recordings; only default ON if it wins.

**Verify with wer.py.** Record the same sentences in a noisy environment, VP off vs on. Ship-on only if VP's WER is clearly lower AND quiet/opening words are not dropped.

---

# How to verify each with `Scripts/wer.py`

Standard harness for every item (it isolates the change from speaking variance by re-transcribing the SAME audio where possible):

1. Prepare a fixed reference set: 15–20 sentences that include your vocabulary terms, homophones, proper nouns, and a few generic sentences. Save each reference string.
2. Read each sentence once; capture VoiceFlow's output as the hypothesis.
3. Score: `python3 Scripts/wer.py --ref "the exact words you read" --hyp "what the app wrote"` (or file form `python3 Scripts/wer.py reference.txt hypothesis.txt`).
4. The tool prints WER% and S/D/I counts plus an aligned diff: `[ref→hyp]` = substitution, `[+word]` = insertion (phantom token), `[-word]` = deletion (dropped word). Read the diff, not just the number:
   - Item 2/3/7 target **substitutions** on vocab/proper nouns.
   - Item 5 targets **insertions** (phantom tokens over silence).
   - Item 6/8 must not introduce new **deletions** (garbling / dropped words).
5. For LOW-risk post-decode items (2, 3), transcribe the SAME saved `.caf` before and after — this removes speaking variance so the WER delta is purely the code change. For capture-path items (6, 8) you must re-record live, so average over the full set to average out speaking variance.
6. Parity check: run the identical set through Wispr as the hypothesis. Per the script's own guidance, within ~1–2 WER points = equivalent. That is the bar.

---

# Sequencing summary

- **This week (LOW risk, no capture-path):** Item 1 (validate) → Item 2 (alternatives + re-rank) → Item 3 (context enrichment) → Item 4 (mic logging). Item 1 gates 3 and 7.
- **Next, behind a live-mic gate (MED):** Item 5 (VAD) — biggest single win against phantom tokens.
- **Then, HIGH-risk, live-mic mandatory, in order:** Item 6 (format normalization) → Item 8 (voice-processing, needs 6) ; Item 7 (custom LM) independently, gated on Item 1's result.
