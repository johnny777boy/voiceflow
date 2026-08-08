# VoiceFlow — Backlog & Handoff (resume point)

Last updated: 2026-08-07 (evening session). Read this first to continue work in a
fresh session. **Read docs/WISPR_GAP_FINDINGS.md too** — 4-agent research answered
"where is the Wispr gap": it's the acoustic model (Wispr = cloud large-model ASR +
context biasing; Apple's engine is whisper-small-class), plus several self-inflicted
cleanup errors listed there.

## Current state
- **`main` = MERGED Whisper version (2026-08-08)** — the Whisper branch was merged
  after TRIPLE verification (senior reviewer agent + adversarial concurrency agent
  + Codex external PASS on `93c59ae`). 106 tests, 0 warnings. Running live on the
  user's machine, model downloaded (1.5GB), user-confirmed working well.
- Tags: `verified-2026-08-08-whisper` (current) · `pre-whisper-merge-2026-08-08`
  (instant rollback: `git reset --hard pre-whisper-merge-2026-08-08`).
- The branch is fully merged; future work continues on new branches off main.
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
1b. **DONE on branch (commit b43b0db)** — verbatim-fidelity pass: true Raw mode,
   spoken punctuation opt-in, filler/guard fixes, Whisper anti-hallucination.
   Only "show rawText in history" remains open from this list.
1c. **Deferred review findings** (2026-08-08 merge verification, two reviewer
   agents; all non-blocking, recorded for later):
   - Whisper path ignores user vocabulary (promptTokens biasing — plan item that
     didn't ship; verify WhisperKit PR#514 first). Asymmetric vs Apple path.
   - whisperModelVariant override doesn't invalidate the cached folder of the
     old variant (dev-only A/B footgun) — add folder-matches-variant check.
   - CleanupGuard.sharesStem false-accepts prefix supersets ("there"→"therefore");
     add max-length-ratio cap.
   - Mic level micro-race can leave audioLevel stuck nonzero after stop
     (invisible today; fix = decide-and-emit under lock).
   - Hotkey rebuild during an active hold swallows the release (wake-while-
     holding only; fix = emit .released from unregister when chord was down).
   - Hide the Whisper toggle on macOS < 26 (LiveSpeechDictation has no fileURL —
     toggle downloads 1GB then silently falls back every dictation).
   - Cancelled downloads leave bounded ~1GB .incomplete files in App Support.
   - Consider moving capture-file deletion ownership to the controller (today:
     Whisper deletes on success; Apple's stale fileURL is a benign dangling ref).
   - WhisperModelManager state-machine unit tests (needs injectable manager).
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
