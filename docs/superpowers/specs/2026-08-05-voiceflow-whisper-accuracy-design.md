# VoiceFlow — Accuracy Engine (Local Whisper) — Design

Date: 2026-08-05
Status: Approved direction (local Whisper); spec for Phase 1.

## Problem

Dictated words are wrong ("now the pill" → "not appeals"). Root cause is **not**
the microphone or audio quality (capture is clean 48 kHz mono). It is two software
issues:

1. **Streaming recognition guesses early.** `SFSpeechRecognizer` transcribes live,
   committing to words before hearing the full sentence, so homophones and
   context-dependent words come out wrong.
2. **Pause-stitching drops audio.** The multi-segment restart (added for long
   dictation) loses a fraction of a second of audio at each pause seam.

## Goal

Wispr-grade accuracy: record the whole utterance, transcribe it **once with full
context** using a Whisper model, then insert. Private (on-device), offline, no
per-use cost.

## Approach (chosen)

Replace live streaming with **record → Whisper batch → clean → insert**:

- **Capture:** while the key is held, tap the mic and accumulate the full audio
  into a single buffer, resampled to **16 kHz mono Float32** (Whisper's native
  input). No recognition during capture — the waveform pill is driven by the live
  level as today.
- **Transcribe on release:** feed the whole buffer to a local Whisper model via
  `whisper.cpp` (Metal-accelerated on Apple Silicon). Model: `large-v3-turbo`
  (best accuracy/speed), with a smaller `base.en`/`small.en` option for slower
  machines.
- **Latency:** ~1–2 s after release (the "Transcribing…" pill state) — the same
  pause Wispr has. Worth it for correctness.
- **Fallback:** if the Whisper model file isn't present yet (first run, still
  downloading), fall back to the existing Apple recognizer so the app always works.

## Components

- `WhisperModelStore` — locates/downloads/validates the ggml model in Application
  Support; exposes readiness. First run: prompt + background download with progress.
- `WhisperTranscriber : Transcribing` — wraps `whisper.cpp`; takes an
  `AudioCapture` (16 kHz mono) and returns `TranscriptionResult`. Runs off the main
  actor; bounded by a timeout.
- `RecordingAudioCapture : AudioRecording` — taps the mic, resamples to 16 kHz
  mono, accumulates samples, reports live level for the pill. Replaces the
  streaming role of `LiveSpeechDictation`.
- Coordinator wiring: choose `WhisperTranscriber` when the model is ready, else the
  Apple transcriber. Vocabulary → Whisper `initial_prompt` for name/term bias.
- Keep the destination-guarded **paste-into-focused-field** insertion unchanged
  (already correct, Wispr's method).

## Data flow

hold key → `RecordingAudioCapture` accumulates 16 kHz mono → release →
`AudioCapture` → `WhisperTranscriber.transcribe` (full-context) → cleanup →
destination guard → paste. Pill: `recording` (waveform) → `processing` → done.

## Error handling

- Model missing/corrupt → Apple fallback + a one-time notice to finish setup.
- Transcription timeout (e.g. > 20 s) → return best-effort text or copy to clipboard.
- Empty/near-silent capture → no-op with a gentle pill message.
- Never lose text: always write to history + clipboard even if insertion fails.

## Testing

- `VoiceFlowTestKit`: unit-test `WhisperModelStore` state machine (missing →
  downloading → ready → corrupt), transcriber selection logic, and audio
  accumulation/resampling math with synthetic buffers. Whisper inference itself is
  validated manually with a known clip (fixture) since it needs the model.

## Later phases (tracked, not this spec)

2. Reliability: onboarding permission check for all 4 grants; graceful no-field.
3. Wispr-parity features: AI formatting per app, dictionary UI, snippets, stats.
4. Polish: modernize main window; onboarding.

## Non-goals

No cloud transcription; no auto-send ever (newlines→spaces on any type fallback).
