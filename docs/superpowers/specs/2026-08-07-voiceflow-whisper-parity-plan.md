# VoiceFlow → Whisper/Wispr Word-Parity Plan

*For one non-native English speaker. macOS 26, Apple Silicon, Command Line Tools only (NO Metal compiler — `xcrun -f metal` fails), SwiftPM. Engine sits behind the `Transcribing` seam.*

Date: 2026-08-07
Author: lead engineer synthesis (on-device / cloud / accent / architecture / decision findings)

---

## 0. TL;DR — the one decision you must make

There is exactly one fork worth agonizing over, and it is **privacy vs. certainty**:

- **Path A (recommended): on-device WhisperKit (CoreML/ANE), `large-v3-turbo`, as a user-selectable "Accuracy mode."** Keeps audio on your Mac, keeps Apple SpeechAnalyzer as the instant default, and — because CoreML runs on the Neural Engine — gets Whisper-large accuracy *without* the missing Metal compiler and without CPU-bound latency. The catch: WhisperKit building under CLT-only is **unverified on this machine**, so Path A is gated behind a 30-minute build spike.
- **Path B (the certain one): cloud Groq `whisper-large-v3`, opt-in, off by default.** Guaranteed to work, ~1s round-trip, best-of-Whisper accuracy on accents, cents/month. The only cost is the thing you said you'd prefer to avoid: audio leaves the device.

**Everything else is settled and should just be done.** Below, section 1 is the honest recommendation, section 2 is the concrete integration for Path A behind the seam, section 3 is the fallback/hybrid design (whisper.cpp CPU-only and cloud), and section 4 is how to *prove* parity with `Scripts/wer.py` on your own voice before committing.

---

## 1. Honest recommendation (single best path for this user + this machine)

Do the cheap Apple levers this week regardless, then run the **WhisperKit CLT build spike** — because on-device WhisperKit on the Neural Engine is the *only* option that satisfies all three of your hard constraints at once (Whisper-large word accuracy for an accented non-native speaker, interactive latency, and audio-never-leaves-device privacy), and the missing Metal compiler does **not** block it (CoreML ships its ANE/GPU kernels precompiled in the OS; only build-time `.metal` shader compilation is unavailable, which CoreML never needs). If the 30-minute spike builds and transcribes one buffer under Command Line Tools, ship WhisperKit `large-v3-turbo` as an opt-in "Accuracy mode" with Apple SpeechAnalyzer remaining the default fast tier; if the spike fails to build, fall back to **whisper.cpp CPU-only** (guaranteed to compile with `-DGGML_METAL=OFF -DGGML_ACCELERATE=ON`, but multi-second on CPU so it must be chunked/streamed, not batch-after-release); and expose **cloud Groq `whisper-large-v3`** as a clearly-labeled, off-by-default opt-in for the sessions where you consciously trade privacy for the last point of accent WER. Critically, gate the whole engine-swap on measurement: record 3–5 clips of *your* voice and run `Scripts/wer.py` Apple-vs-Whisper on the identical audio — if Apple + contextual-strings + a custom LM already land within 1–2 WER points of Whisper on your accent, **stop and ship Apple**, because Whisper's size and latency aren't worth buying accuracy you already have.

Why not "just Apple" (the conservative read)? Apple's single best accent lever is **locale selection** (`en_IN`, `en_GB`, …), and for a non-native speaker whose L1 has **no shipped `en_*` model**, that lever is largely inert — which is exactly why your accent tail persists and why Whisper (trained on ~1M hours including heavy non-native English, with a strong decoder-LM that recovers acoustically-fuzzy words from context) is the real fix. Why not "just cloud"? It's the certain path, but it violates the privacy stance for *every* utterance, and on-device WhisperKit gets you ~90% of the same accuracy with none of that cost — so cloud earns a toggle, not the default.

---

## 2. Integration plan for Path A (WhisperKit, on-device) behind the `Transcribing` seam

The seam is already a perfect fit. `Transcribing.transcribe(_ audio: AudioCapture, languageCode:) async throws -> TranscriptionResult` hands you `AudioCapture.samples: [Float]` (mono, normalized) plus `sampleRate` — Whisper is inherently a batch/30s-window model, so no protocol change is required. `TranscriptionResult` already carries `confidence`, which the hybrid router in §3 uses.

### Step 0 — Free Apple wins first (do these regardless of the fork; ~1 day, LOW risk)
These are the cheapest WER points available and they raise the bar Whisper has to beat:
1. **Wire `contextualStrings` into the modern path.** Per the accuracy findings they are declared but silently dropped on `SpeechAnalyzerDictation`; the legacy `LiveSpeechDictation` applies them. Feed the user's vocabulary, contact names, active-app/window title, and jargon.
   - File: `Sources/VoiceFlowApp/Platform/SpeechAnalyzerDictation.swift` (`transcribe()` — set `AnalysisContext.contextualStrings`).
2. **Insert a `SpeechDetector` (VAD)** ahead of the transcriber to trim dead air / phantom tokens.
3. **Compile an `SFCustomLanguageModelData`** (weighted vocab + X-SAMPA custom pronunciations) for names Apple persistently mangles on this accent. Heavier — do only if 1–2 measurably fall short.
- **Do NOT reach for `.atypicalSpeech` / atypical-speech content hints.** That feature targets speech *disorders* (dysarthria), not foreign accents; using it for a typical-but-accented speaker can *degrade* results.

### Step 1 — The gating spike (30 min, do FIRST) — **HIGH-RISK / decides the path**
Add the SPM dep, `swift build` under Command Line Tools, load the `base` model, feed one `AudioCapture.samples` buffer, confirm text out. Pass/fail decides Path A vs. the whisper.cpp fallback.
- `Package.swift`:
  ```swift
  .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0")
  // target dep: .product(name: "WhisperKit", package: "argmax-oss-swift")
  ```
- Risk: Argmax lists "Xcode 16+" as a prerequisite. Their *sources* are pure Swift (deps `swift-transformers`, Jinja are pure Swift) and CoreML's runtime compile (`MLModel.compileModel`) lives in the SDK CLT already vends, so it *should* `swift build` under CLT — but this is **unverified on this machine**. If it fails to build, abandon Path A and go to §3.1 (whisper.cpp).

### Step 2 — Implement `WhisperKitTranscriber: Transcribing` (MEDIUM risk)
New file: `Sources/VoiceFlowApp/Platform/WhisperKitTranscriber.swift`.
- `transcribe(_:languageCode:)`:
  - **Resample** `audio.samples` from `audio.sampleRate` → **16 kHz mono** (WhisperKit's required input) using Accelerate `vDSP` / `AVAudioConverter`. *(HIGH-RISK: a resampling error silently produces garbage transcripts — unit-test the resampler against a known WAV before trusting it.)*
  - Call `whisperKit.transcribe(audioArray:)`, map result `text` + average logprob → `TranscriptionResult(text:confidence:)`.
  - **Force decoder options** (the accent-accuracy findings, ranked): `language = "en"` (never auto-detect — mis-ID is a catastrophic failure mode on heavy accents), `task = .transcribe`, `temperature = 0` **with** the fallback schedule enabled, `conditionOnPreviousText = false` (prevents error cascades on short dictation), plus `no_speech`/`logprob` gating for hallucination control. Pass your existing `contextualStrings`/vocabulary as the **initial decoding prompt** — Whisper's equivalent of a custom vocabulary and a high-impact lever for proper-noun/jargon tail errors.
- `requestPermission()`: fully local, no speech entitlement — return `true` after the mic permission `AudioRecording` already handles.

### Step 3 — Engine selection + model management (LOW risk)
- Add a settings enum alongside your existing engine switch (`Sources/VoiceFlowApp/Platform/SpeechEngine.swift`):
  ```swift
  enum TranscriptionEngine: String, Codable {
      case appleSpeechAnalyzer   // default (fast, private, instant)
      case whisperLocal          // opt-in "Accuracy mode", downloaded on first use
      case whisperCloud          // opt-in, requires key; off by default
  }
  ```
- Model: ship `large-v3-turbo` (~954 MB, or ~626 MB compressed `large-v3`) in the bundle for offline/air-gapped, **or** lazy-download on first "Accuracy mode" enable with a progress UI. `turbo`'s 4-layer decoder is the best accuracy/latency point on ANE.
- Inject the chosen `Transcribing` in `Sources/VoiceFlowApp/AppCoordinator.swift`.

### Step 4 — Keep latency Wispr-fast (see §3.3; do NOT skip for Whisper) — **HIGH-RISK / needs live-mic testing**
WhisperKit on ANE is ~5–15× real-time, so it is *usable* batch-after-release. But the current pipeline is strictly serial (`DictationController.finishRecording` L87–121: transcribe → cleanup → insert), and the **LLM cleanup pass (1–2s) blocks insertion**. Land the latency work in §3.3 before/with the engine swap or the Wispr feel regresses.

**Files to change (Path A):** `SpeechAnalyzerDictation.swift` (Step 0), `Package.swift` (Step 1), new `WhisperKitTranscriber.swift` (Step 2), `SpeechEngine.swift` + `AppCoordinator.swift` (Step 3), `DictationController.swift` + `CleanupPipeline.swift` + `FoundationModelsCleanupProvider.swift` (Step 4 / §3.3).

---

## 3. Fallback + hybrid design

### 3.1 Build-fallback: `WhisperCppTranscriber` (CPU-only, guaranteed to compile)
If the Step-1 spike fails to build under CLT:
- Vendor `whisper.cpp` + `ggml*.c` as a **C SwiftPM target**: define `GGML_USE_ACCELERATE`, leave `GGML_METAL` undefined, `.linkedFramework("Accelerate")` (NEON + Accelerate/AMX). Do **not** use the prebuilt `whisper.spm` XCFramework — it's typically built *with* Metal.
- New file: `Sources/VoiceFlowApp/Platform/WhisperCppTranscriber.swift`, same `Transcribing` conformance and same decoder options as §2 Step 2.
- Default to `small` (~466 MB, 2–4× faster) with `large-v3-turbo` as a "max accuracy" toggle. Honest latency: `large-v3-turbo` CPU-only is roughly **1–3× real-time** (a 10s clip → ~4–10s), `small` ~2–4× faster.
- **Consequence:** CPU-only batch-after-release is too slow for interactive dictation on long utterances → it *must* be chunked/streamed (§3.3-E), not a drop-in batch swap. This is why WhisperKit/ANE is preferred.

### 3.2 Runtime hybrid: "Apple-first, Whisper-on-doubt" + graceful cloud fallback
Apple stays primary for speed/privacy/size; Whisper is the tail-accuracy insurance. Because audio is already buffered for batch finalize, re-running a second engine on the *same* buffer is free of extra recording.

- **Automatic second opinion:** always transcribe with Apple; if Apple's finalized `confidence` is below threshold **or** the utterance contains a known-hard vocabulary token, and the user enabled Whisper, re-transcribe the same buffer with local Whisper and keep the higher-confidence / vocabulary-consistent result.
- **Manual affordance:** a "re-transcribe this one" key on the pill to force a second opinion without changing the default.
- **Cloud path** (`WhisperCloudTranscriber`, Groq `whisper-large-v3`, OpenAI-compatible multipart): wrap in a `FallbackTranscriber` decorator that drops to Apple on any error/offline/no-key/timeout (15s request timeout = fallback trigger). Encode `[Float]` → 16-bit PCM WAV in memory (no disk). Language = ISO-639-1 (`"en"`, trimmed from BCP-47). Pass the same custom vocabulary as the `prompt` field for cross-engine parity. **API key in `KeychainStore`, never UserDefaults/Info.plist**; blank key ⇒ behave as if cloud is off, never throw at the user. Label the toggle clearly: "audio leaves your Mac." Off by default, never silent. New file: `Sources/VoiceFlowApp/Platform/CloudWhisperTranscriber.swift`; inject in `AppCoordinator.swift`.
  - Model choice: default **full `whisper-large-v3`**, not turbo — the entire reason to go cloud is accent word-accuracy, and turbo (~8.4% WER) trades some of it away vs. full v3 (~7.6%). Cost is a non-issue (~$0.30 per 1,000 ten-second clips). If you later want Wispr-style partials-as-you-speak, add a **Deepgram Nova-3** streaming adapter (~6.8% WER, best accent tolerance) as a second cloud adapter behind the same seam.

### 3.3 Latency architecture — keep the Wispr feel regardless of engine
The perceived cost is release→text, and it's dominated by the serial LLM cleanup, not transcription. Ordered by impact-per-effort:
- **A. Warm the LLM session (biggest free win, ~300–800ms).** `FoundationModelsCleanupProvider` builds a fresh `LanguageModelSession` every call — create one long-lived session at launch and prewarm it during mic warm-up. File: `FoundationModelsCleanupProvider.swift`.
- **B. Tier/skip LLM cleanup** for short utterances (< ~8 words) and low-stakes modes (Slack/iMessage); keep it for email/clean-writing. File: `CleanupPipeline.swift`.
- **C. Move the 0.18s drain off the main thread** and shrink to ~80–100ms. File: `SpeechAnalyzerDictation.swift` (`stopRecordingImpl` `Thread.sleep(0.18)`).
- **D. Reuse the analyzer/transcriber instance** instead of rebuilding the graph each call. File: `SpeechAnalyzerDictation.swift`.
- **E. Two-phase delivery (the Wispr trick) — needs a new primitive, MEDIUM risk.** Insert the deterministic rule-cleaned result immediately, refine with the LLM asynchronously, replace in place. Requires a `replaceLastInsertion(range:with:)` on `TextInserting` (currently only `insert`/`copyToClipboard`). Files: `Sources/VoiceFlowCore/Protocols/TextInserting.swift`, `AccessibilityTextInserter.swift`, `DictationController.swift`. **HIGH-RISK / needs live-mic testing** — select-back + retype can misfire across apps; gate behind a setting for v1.
- **F. For any Whisper engine: chunk/stream while the key is held** (rolling windowed decode) so only the ~1–2s tail remains at release, instead of paying utterance-length compute after release. Add an optional partial callback to the seam; keep `TranscriptionResult` as the final. Essential for whisper.cpp CPU; a nice-to-have for ANE.
- Add a **release-to-insert metric** first — the current `latencySeconds` includes hold time and won't show the number you're tuning.

**Sequencing:** ship A+B+C (pure latency, no new primitive, no accuracy risk) → measurement (§4) → engine spike (§2 Step 1) → engine swap with E/F as needed.

---

## 4. Proving parity with `Scripts/wer.py` on the user's own voice

The 30%-weighted "accuracy on *his* voice" number must be **measured, not assumed**. `Scripts/wer.py` (Levenshtein word-error over normalized text) is the instrument. Two protocols:

### 4.1 Engine-vs-engine on identical audio (decides whether to build Whisper at all)
Eliminates the audio variable by feeding one recording to both engines:
1. Record 3–5 WAVs of the user reading the ~100-word passage in `docs/ACCURACY_BENCHMARK.md` plus the 5 hard sentences (homophones, proper nouns, decimals like `3.14`, abbreviations like `U.S.`, `Dr. Smith`) — accented, natural pace. One sentence is noise; five is signal.
2. Feed the identical WAV through Apple `SpeechAnalyzer` → `apple.txt` and through Whisper (`large-v3` / WhisperKit `large-v3-turbo`) → `whisper.txt`.
3. Score both against the reference:
   ```bash
   python3 Scripts/wer.py reference.txt apple.txt
   python3 Scripts/wer.py reference.txt whisper.txt
   ```
4. **Decision rule:**
   - Apple within 1–2 pts of Whisper → **ship Apple-only; do not build the Whisper engine.**
   - Whisper better by >2–3 pts *and* errors cluster on proper nouns/jargon → first close it with contextual strings + custom LM on Apple, **re-measure**.
   - Gap persists after those levers → **build the local-Whisper opt-in** (§2), confidence-gated (§3.2).
5. Log per-run WER, S/D/I breakdown, latency, and engine into a small CSV so the choice is data, revisited as vocabulary grows.

### 4.2 App-vs-app: VoiceFlow vs. Wispr (the parity proof)
Per `docs/AB_TEST_WISPR.md`: **VoiceFlow in Raw mode** (isolates transcription from cleanup), cursor in a Note, read each reference sentence once, then read the *same* sentences into Wispr.
```bash
python3 Scripts/wer.py --ref "Their proposal was accepted and they were thrilled with the results." \
                       --hyp "WHAT THE APP WROTE"
```
Run once with VoiceFlow's output as `--hyp`, once with Wispr's. The aligned diff names exactly which words failed — that's your fix list (contextual strings / custom pronunciation / initial prompt).

### 4.3 Stopping condition
Target: **≤5% WER on his voice in Raw/Clean, matching Wispr within 1–2 points.** When Apple + Step-0 levers hit that, **stop** — the Whisper engine is unnecessary size, latency, and complexity. Only a measured, persistent accent tail justifies building it.

---

## 5. Feasibility under NO Metal compiler — the bottom line
`xcrun -f metal` failing only removes **build-time `.metal` shader compilation**. It does **not** block runtime CoreML/ANE (WhisperKit) — those kernels ship precompiled in the OS — and it does **not** block whisper.cpp built CPU-only. It **does** block MLX / mlx-swift (compiles its own Metal kernels) and makes ONNX Runtime's CoreML EP not worth the heavy C++/SPM pain. So: **WhisperKit is the accuracy+latency pick, whisper.cpp CPU-only is the guaranteed-buildable fallback, cloud Groq is the certain escape hatch, MLX is out.** On-device Whisper parity is feasible on this machine — verify the CLT-only WhisperKit build first, and let WER on your own voice decide whether you even need it.
