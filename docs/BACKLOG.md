# VoiceFlow — Backlog & Handoff (resume point)

Last updated: 2026-08-07. Read this first to continue work in a fresh session.

## Current state
- **`main` = `761cd84`** — the STABLE, working version. This is what's installed and
  what to keep using. Fast Apple SpeechAnalyzer engine, on-device cleanup, insertion,
  all fixes below. Codex-verified (2 rounds), 93 tests pass, 0 warnings.
- **Whisper work is on branch `feature/system-dictation-daily-use` (`a974ee3`)**, pushed
  to GitHub but NOT merged — it's incomplete (see Open Items #1).
- Repo: github.com/johnny777boy/voiceflow. Worktree:
  `.worktrees/feature-system-dictation-daily-use`.

## Restore points (git tags on GitHub)
- `verified-2026-08-07` (Codex-verified) · `known-good-2026-08-06b` · `known-good-2026-08-06`
  · `known-good-2026-08-05`.
- Revert anytime: `git reset --hard <tag> && git push --force origin main`.

## What works (done)
- Insertion into any focused app (clipboard+⌘V, Wispr's method); never auto-sends;
  secure-field & wrong-app guarded. Stable code-signing so macOS permissions persist.
- Apple **SpeechAnalyzer** (macOS 26) record-then-transcribe engine; warm mic + pre-roll
  (first word not clipped); trailing drain (last word not clipped); final-only results;
  region-aware locale; vocabulary contextualStrings + n-best re-ranking.
- On-device **Foundation Models** cleanup (no API key), always-on, meaning-preserving
  guard (negation/number), strips leaked "Here is the cleaned text:" preambles.
- Deterministic formatting (punctuation, spacing incl. gap after glued punctuation,
  capitalization guarding decimals/initialisms), leading space between consecutive
  dictations, auto best-fit mode per app, waveform pill UI.
- Tooling: `Scripts/wer.py` (WER scorer), `docs/ACCURACY_BENCHMARK.md`,
  `docs/AB_TEST_WISPR.md`, `docs/CODEX_VERIFICATION_2026-08-06.md`.

## Known limitations (the honest ASR ceiling on the Apple engine)
These are NOT bugs — they're the recognizer's hardest cases, worse for a non-native
accent, and even Wispr slips on them:
- **Short function words at the start** ("are you" → "I'm"; he/she/you) — hardest case.
- **Occasional phantom/hallucinated words** on ambient/silence.
- Root cause: Apple's model is native-English-biased; the user's L1 has no matching
  Apple locale, so Apple's accent levers are largely inert. **Whisper handles accents
  better** (trained on diverse/accented speech) — that's Open Item #1.

## Open items — continue from here (priority order)
1. **Make on-device Whisper (WhisperKit) usable** ⭐ — the real fix for the accent gap.
   - Status: it's BUILT and PROVEN FEASIBLE on this no-Metal Mac (WhisperKit compiles
     under Command Line Tools; Core ML uses the Neural Engine). Opt-in toggle exists
     (Settings ▸ Privacy & AI, UserDefaults key `useWhisperEngine`).
     `WhisperKitTranscriber.swift` transcribes the recorded file (via
     `AudioCapture.fileURL`); `SpeechAnalyzerDictation` stays the recorder.
   - **Blocker:** the first dictation FAILS/hangs because it downloads the ~1 GB model
     inline. MUST: download the model in the BACKGROUND on toggle-on with a progress
     UI, and never let a dictation fail while downloading (fall back to Apple until
     ready). Also verify the model name/download works at runtime (untested on mic).
   - Then measure: `Scripts/wer.py` Apple-vs-Whisper on the user's own voice; keep
     Whisper only if clearly better for them. Plan: `docs/superpowers/specs/2026-08-07-voiceflow-whisper-parity-plan.md`.
2. **(Optional) Noise suppression / voice-processing IO** on the mic input — untested
   audio lever that helps short-word clarity. HIGH-RISK (touches capture); test live.
   Plan: `docs/superpowers/specs/2026-08-06-voiceflow-transcription-accuracy-plan.md`.
3. **(Optional) Cloud Whisper (Groq)** — fast + accent-strong, but audio leaves the
   device. Off-by-default opt-in only.

## Lessons (don't repeat)
- NEVER push blind audio-path changes — they can't be verified without the mic and
  have broken things twice. Change audio ONLY with the user present to test + WER.
- Keep `main` at a known-good tag; do risky work on the branch; measure before merge.

## Daily use
Use **Clean Writing** mode (auto-mode picks it). Whisper toggle is OFF (stable Apple
engine). ~93–95% accuracy on clear speech; the accent tail is the ceiling until Item #1.
