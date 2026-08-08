# VoiceFlow — Working Rules (read me first)

macOS push-to-talk dictation app (SwiftPM, macOS 26, Command Line Tools only — no
Xcode, no XCTest; tests are the executable `swift run VoiceFlowTests`). The bar is
**Wispr Flow parity** with a privacy edge: everything on-device.

## The workflow (non-negotiable ritual, agreed with Yoni)

1. **All work on a feature branch off `main`.** `main` is always the last
   verified-good version, tagged.
2. **The installed app IS the staging environment.** Build from the branch
   (`Scripts/build_app.sh`), back up `/Applications/VoiceFlow.app` if it isn't
   already reproducible from a tag, install (`ditto dist/VoiceFlow.app
   /Applications/VoiceFlow.app`), relaunch. Yoni tests by *living on it* with his
   real voice. There is no other staging.
3. **Yoni approves by experience, not by reading diffs.** If he doesn't like it:
   delete the branch, reinstall from main — main never knew.
4. **Before merge: triple verification.** (a) A senior reviewer agent on the full
   branch diff; (b) an adversarial concurrency/lifecycle reviewer agent trying to
   break it; (c) an external Codex verification — write/refresh a brief in
   `docs/CODEX-BRIEF-*.md` (self-contained: diff range, claims to verify,
   invariants to attack, build/test commands, accepted tradeoffs NOT to flag),
   give Yoni a short paste-message, and wait for his pasted PASS verdict.
   Fix every Critical/Important finding before merging.
5. **Merging:** tag main first (`pre-<thing>-merge-YYYY-MM-DD`), `git merge
   --no-ff`, run tests on the merge, tag `verified-YYYY-MM-DD-<thing>`, push with
   tags, rebuild + reinstall the app from main.
6. **NEVER change the audio-capture path blind** (tap, formats, preroll, drain,
   voice-processing). Twice it broke things unverifiable without a mic. Audio
   changes happen only with Yoni present, verified live + by WER.
7. **Every session updates** `docs/BACKLOG.md` (resume point) and
   `.claude/status.json` (dashboard) before ending.

## Product principles (Yoni's standing decisions — do not relitigate)

- **Verbatim fidelity outranks everything**: never insert words the user didn't
  say; never let cleanup add/remove/replace words (CleanupGuard is bidirectional
  and strict — synonym swaps are rejected on purpose). Silence must produce
  NOTHING (phantom defense: energy gate + suppress tokens + short-clip
  Apple-engine arbiter).
- **Uniform formatting everywhere** (2026-08-08): the same speech produces the
  same formatted text in EVERY text box — chat, email, terminal, everything.
  No app defaults to code mode; code mode exists only as an explicit per-app
  user setting.
- **Continuation gaps always** (Wispr rule): a word before the caret ⇒ a space
  before the new text — even in AX-blind web/Electron fields (tier-2 continuation
  memory in AccessibilityTextInserter).
- **Never auto-send** (no Enter). Never claim "Inserted" when no text field was
  focused ("doesn't insert" reports are usually an unfocused field, not a bug).
- **English only for now.** Hebrew is planned as a SECONDARY language later
  (English stays primary). No other languages until then.
- **Privacy is the moat**: audio never leaves the Mac; models on-device; history
  local. Cloud anything = off-by-default opt-in with explicit labeling.

## Architecture crib (details in docs/)

- Engines behind the `Transcribing` seam: `SpeechAnalyzerDictation` (Apple,
  records to file + transcribes) and `WhisperKitTranscriber` (reads the same
  file; model lifecycle in `WhisperModelManager`, background download).
  `FallbackTranscriber` routes per-dictation: Whisper when enabled+ready, Apple
  otherwise and on any Whisper failure — a dictation can never fail because of
  Whisper. Whisper deletes the capture file ONLY on success.
- Cleanup: `RuleBasedCleanup` (raw/off = truly verbatim) → optional on-device
  LLM (`FoundationModelsCleanupProvider`) gated by strict `CleanupGuard`.
- Known trap: WhisperKit `noSpeechThreshold` is dead config in v0.18 (re-audit
  on version bump). Model names must match the HF repo folders exactly
  (`openai_whisper-large-v3-v20240930_turbo`).
- Signing: `Scripts/build_app.sh` uses the stable "VoiceFlow Local Signing"
  identity (keychain must be unlocked) so macOS permissions persist.

## Key docs

- `docs/BACKLOG.md` — resume point (read first in every session)
- `docs/ROADMAP.md` — phased upgrade plan toward sellable quality
- `docs/WISPR_GAP_FINDINGS.md` — the research answer on the Wispr gap
- `docs/ACCURACY_BENCHMARK.md` + `Scripts/wer.py` — measurement protocol
