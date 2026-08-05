# VoiceFlow — Accuracy + Cleanup Engine — Design (Phase 1)

Date: 2026-08-05
Status: Approved direction. Engine choice revised after research (see below).

## Problem

1. Dictated words are wrong ("now the pill" → "not appeals"). Not the mic — the
   audio capture is clean 48 kHz mono. Cause: Apple's **legacy streaming**
   recognizer (`SFSpeechRecognizer`) guesses words before hearing the sentence,
   plus our pause-stitching drops a sliver of audio at each pause.
2. The user wants the text to read as **clean, correct English** even when the
   spoken words are rough ("Whisper somehow fixes it"). That is a separate
   AI-cleanup layer, not transcription.

## Research outcome (why the engine changed)

- The user is on **macOS 26** (SDK 26.2 confirmed in this toolchain).
- Apple's new **`SpeechAnalyzer` / `SpeechTranscriber`** (WWDC25) benchmarks
  **better than Whisper Small** on English (2.12% vs 3.74% WER) and ~3× faster,
  and cuts WER ~4× vs `SFSpeechRecognizer` (9% → 2%). On-device, private.
- This machine has **no Metal compiler** (CLT only), so bundling whisper.cpp would
  be CPU-only and slow, and adds ~1 GB. `SpeechAnalyzer` needs neither.

**Decision: use `SpeechAnalyzer` + `SpeechTranscriber` as the engine.** It is more
accurate than Whisper here, native, private, tiny, and needs no Metal. (Whisper is
shelved unless we later need its 100-language coverage.)

## Two-layer pipeline

**Layer 1 — Transcription (`SpeechAnalyzer`).** Record while the key is held; on
release, analyze the full audio with `SpeechTranscriber` (preset `.transcription`)
and take the finalized result — full context, so homophones resolve. Feed the
user's vocabulary via `AnalysisContext` contextual strings. Keep the live waveform
pill during capture; show "Transcribing…" for the brief finalize.

**Layer 2 — AI cleanup ("fix my English").** Pass the raw transcript through the
existing `CleanupPipeline` → `LLMCleanupProvider` (Claude, model `claude-haiku-4-5`
by default) with a prompt that fixes grammar, filler, and phrasing **without
changing meaning and without adding content**. Per-mode (email vs chat vs code vs
raw). Default-on when an API key is set; deterministic local cleanup otherwise.
Never auto-send.

## Components

- `SpeechAnalyzerTranscriber : Transcribing` — new; wraps `SpeechAnalyzer`.
  Uses `AssetInventory.reserve(locale:)` + `assetInstallationRequest` to ensure the
  model asset is installed (one-time), gates on `SpeechTranscriber.isAvailable` and
  `supportedLocales`.
- `RecordingAudioCapture : AudioRecording` — taps mic, accumulates buffers, reports
  live level for the pill. (Split capture from recognition.)
- Coordinator: prefer `SpeechAnalyzerTranscriber` on macOS 26 when available; fall
  back to the current live engine otherwise, so the app always works.
- Cleanup: make LLM cleanup robust + default; strong "fix grammar, keep meaning"
  prompt; graceful offline fallback.
- Insertion unchanged (paste into focused field — already correct).

## Error handling

- Model/asset not ready → fall back to Apple legacy engine + one-time setup notice.
- Transcription/finalize timeout → best-effort text or copy to clipboard.
- Cleanup failure/offline → return the raw transcript (never block insertion).
- Never lose text: always store to history + clipboard.

## Testing

`VoiceFlowTestKit`: transcriber-selection logic, availability/asset state machine,
audio accumulation math (synthetic buffers), cleanup-prompt shaping. Live inference
validated manually against a known phrase.

## Full roadmap (Wispr parity) — tracked

- **Phase 1 (this spec):** SpeechAnalyzer engine + AI cleanup. ← accuracy + English.
- **Phase 2 Reliability:** onboarding that verifies all 4 permissions; graceful
  no-field; never-lose-text.
- **Phase 3 Features:** AI formatting/tone per app; custom dictionary UI; snippets /
  text-expansion; usage stats; optional command mode.
- **Phase 4 Polish:** modernize main window to match the pill; onboarding flow.

## Non-goals

No cloud transcription (audio stays on device). Never auto-send (newlines→spaces on
any typing fallback). No feature that sends text anywhere the user didn't target.
