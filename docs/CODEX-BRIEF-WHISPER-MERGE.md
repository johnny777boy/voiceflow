# Codex Verification Brief — Whisper branch → main merge

Repo: github.com/johnny777boy/voiceflow
Branch to verify: `feature/system-dictation-daily-use` (head: latest on branch — includes two internal review rounds)
Merge target: `main` (`05d0e58`)
Diff to review: `git diff 05d0e58..HEAD -- Sources/` (ignore docs/: BACKLOG.md and
WISPR_GAP_FINDINGS.md show as deleted only because they landed on main after the
branch was cut — expected, not a defect).

## Context (one paragraph)

VoiceFlow is a macOS push-to-talk dictation app (SwiftPM, macOS 26, built under
Command Line Tools only — tests are a plain executable, `swift run VoiceFlowTests`,
because the CLT SDK has no XCTest). main = stable Apple SpeechAnalyzer engine.
This branch adds an opt-in on-device Whisper "High Accuracy" engine (WhisperKit
0.18, Core ML/ANE) plus a verbatim-fidelity pass, and is already running live on
the user's machine. We want independent verification before merging.

## What the branch claims to do (verify each)

1. **Whisper engine, never-fail** — `WhisperKitTranscriber` transcribes the file
   recorded by `SpeechAnalyzerDictation` (via `AudioCapture.fileURL`).
   `FallbackTranscriber` (Core) routes per dictation: Whisper only when the toggle
   is on AND the model is loaded; Apple engine otherwise and on ANY Whisper error.
   INVARIANT: a dictation can never fail or block because of Whisper (downloading,
   loading, or crashing). On Whisper failure the capture file must survive so the
   Apple engine can re-read it (Whisper deletes it only on success).
2. **Background model management** — `WhisperModelManager` (@MainActor): toggle-on
   starts a background download (progress published to SettingsView), model stored
   under Application Support/VoiceFlow/Models, reused across launches, pipeline
   loaded + prewarmed off the dictation path. Model variant string
   `openai_whisper-large-v3-v20240930_turbo` (the old `large-v3-turbo` matched
   nothing on HuggingFace — that fix is part of this branch).
3. **Verbatim fidelity** — Raw/off mode is truly verbatim (no vocabulary
   substitution); spoken punctuation ("period"→".") is opt-in via new
   `AppSettings.spokenPunctuationEnabled` (custom tolerant Codable decode so old
   settings.json never resets); filler list no longer contains er/err/ah;
   `CleanupGuard` rejects LLM outputs containing novel words (stem-tolerant:
   "discuss"→"discussing" passes, "pill"→"peel"/"check"→"czech" rejected);
   Anthropic LLM path now also gets preamble-strip + guard.
4. **Anti-hallucination (Whisper)** — energy gate: clip skipped only when
   maxChunkRMS < 0.005 AND peak < 0.015 (verifier-tuned to be far below quiet
   speech); OpenAI non_speech_tokens suppression list built per-model at adopt()
   (WhisperKit 0.18 ships an empty TODO for this); `TranscriptSanity` phantom
   filter drops "Thank you."-class outputs ONLY on whole-transcript match AND a
   doubt signal (avgLogprob < -1.0 or near-silence) — fail-open by design.
   Note: `noSpeechThreshold` is dead config in WhisperKit 0.18 (noSpeechProb
   hardcoded 0) — the branch documents this rather than tuning it.
5. **Perf/UX fixes** — mic level callbacks emitted only while recording (was
   100% idle CPU from ~50 UI publishes/sec through the always-warm tap);
   hotkey event tap rebuilt on NSWorkspace.didWakeNotification (tap silently
   died after overnight sleep); transcribing spinner is a SwiftUI-drawn gradient
   arc (AppKit ProgressView ignores .tint and was invisible dark-on-dark).

## How to verify

1. `swift build` → must be 0 errors, 0 warnings.
2. `swift run VoiceFlowTests` → must print "All 106 tests passed".
3. Read the diff with special attention to:
   - File-lifecycle across failure paths (WhisperKitTranscriber.transcribe:
     energy-gate throw, decode throw, phantom-filter throw — file must NOT be
     deleted on those; Apple fallback consumes it via its internal takeFileURL()).
   - WhisperModelManager state machine: toggle off→on→off flapping, retry after
     failure, cancel mid-download, relaunch mid-download (HubApi resumes).
   - WhisperKit API usage vs the pinned 0.18 checkout (`Package.resolved`):
     `supressTokens` (sic), `transcribe(audioArray:)` expects 16kHz mono float
     (delivered by `AudioProcessor.loadAudioAsFloatArray`), DecodingOptions field
     names, tokenizer `specialTokens.specialTokenBegin`.
   - AppSettings custom `init(from:)`: every field `decodeIfPresent` with defaults
     — old settings.json must decode, missing new key ⇒ false.
   - CleanupGuard novel-word check: can it reject legitimate cleanups too
     aggressively? (Known, accepted policy: synonym substitutions are rejected;
     stem variants pass.)
4. Deliver verdict: PASS (merge) / FAIL (list blocking defects with file:line).

## Known/accepted tradeoffs (do not flag as defects)

- LLM cleanup is more conservative now (novel-word guard) — deliberate policy.
- Release-to-text latency 2–4s in Whisper mode — latency plan exists, out of scope.
- promptTokens vocabulary biasing deferred (needs WhisperKit PR#514 verification).
- `AudioCapture.sampleRate: 16_000` is cosmetically wrong (real 48k) but unused
  on this path — documented, harmless.
- Preroll is 0.8s (may transcribe pre-keypress speech) — audio-path change
  deferred until a live-mic session, per project rule.
