# VoiceFlow — Backlog & Handoff (resume point)

Last updated: 2026-08-07 (evening session). Read this first to continue work in a
fresh session. **Read docs/WISPR_GAP_FINDINGS.md too** — 4-agent research answered
"where is the Wispr gap": it's the acoustic model (Wispr = cloud large-model ASR +
context biasing; Apple's engine is whisper-small-class), plus several self-inflicted
cleanup errors listed there.

## Current state
- **`main` — the STABLE, working version** (code unchanged from `761cd84`; docs-only
  commits since). Fast Apple SpeechAnalyzer engine, on-device cleanup, insertion,
  all fixes below. Codex-verified (2 rounds), 93 tests pass, 0 warnings.
- **Whisper work is on branch `feature/system-dictation-daily-use` (`dee4585`)**, pushed
  to GitHub, NOT merged. Open Item #1's blocker is now FIXED in code: background
  model download with progress UI (Settings ▸ Privacy & AI), Apple-engine fallback
  until Whisper is ready and on any Whisper failure (FallbackTranscriber, tested),
  correct model name `openai_whisper-large-v3-v20240930_turbo` (the old
  "large-v3-turbo" matched nothing on HF and always failed), tuned decode options.
  98 tests pass, 0 warnings. **Remaining: live-mic validation + WER A/B** (below).
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
1. **Validate Whisper mode on live mic + WER A/B** ⭐ — code is done (see Current
   state); needs the user present. Steps: build/install from the branch, toggle
   High Accuracy on, watch the download progress bar finish (~1 GB → "Whisper is
   ready"), dictate; then `Scripts/wer.py` Apple-vs-Whisper on the user's voice
   (protocol: docs/ACCURACY_BENCHMARK.md + parity plan §4). A/B the accuracy
   ceiling via UserDefaults `whisperModelVariant` = `openai_whisper-large-v3_turbo`
   (FULL large-v3, ~1 WER better on accents, slower). Keep Whisper only if
   measurably better. Plan: `docs/superpowers/specs/2026-08-07-voiceflow-whisper-parity-plan.md`.
1b. **Fix self-inflicted word errors** (from WISPR_GAP_FINDINGS.md, all cheap):
   spoken-punctuation replacements destroy literal "period"/"comma" (on by
   default); Raw mode isn't raw (VocabularyReplacer runs first — corrupts WER
   benchmarks); rawText stored but never shown in history; CleanupGuard missing
   on the Anthropic provider path. Do these BEFORE trusting any WER numbers.
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
