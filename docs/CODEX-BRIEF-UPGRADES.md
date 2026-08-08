# Codex Verification Brief — upgrades Phases 1–5 → main merge

Repo: github.com/johnny777boy/voiceflow
Branch to verify: `feature/upgrades-phase1-5` (head `539465b` — verify whatever HEAD is when you start)
Merge target: `main` (`7b8f8fd`)
Diff: `git diff 7b8f8fd...HEAD -- Sources/`
Build/test: `swift build` and `swift build -c release` (both 0 warnings) ·
`swift run VoiceFlowTests` → "All 172 tests passed".

macOS 26, SwiftPM, Command Line Tools only — there is no Xcode and no XCTest on
this machine. The suite is a plain executable target; that is deliberate, not a
gap to flag.

## Context

Five phases built autonomously in one session against the plan in
`docs/ROADMAP.md`, then put through two internal reviewer agents (a senior
reviewer and an adversarial concurrency/lifecycle reviewer). Both rounds' Critical
and Important findings are already fixed in `539465b` — that commit's message is
the full list, and it is worth reading first: it tells you exactly where the
sharp edges were, which is where your attention is most valuable.

The app is installed and the user is dictating on it live. Nothing merges until
you return a verdict.

## What each phase does

1. **Context biasing** — the user's enabled vocabulary plus proper nouns read off
   the frontmost window (via Accessibility TEXT, never screenshots, never
   uploaded) are encoded as Whisper `promptTokens`. Verified against the pinned
   WhisperKit 0.18.0 that prompt tokens are prefixed with `startOfPreviousToken`,
   filtered below `specialTokenBegin`, and bypass the prefill KV-cache (PR #514
   behavior), so no package bump.
2. **Measurement** — `insertLatencySeconds` (release→insert, hold time excluded)
   and `editedAfterInsert` per record, additively migrated into SQLite; history
   cards show the verbatim "heard" text whenever cleanup changed anything.
3. **Latency** — LLM prewarm at key-down; short casual utterances skip the LLM
   pass; the 0.18s trailing drain became an async suspension before the
   main-thread stop; two-phase delivery behind an OFF-by-default setting.
4. **Learning dictionary** — post-insertion corrections observed via AX propose
   vocabulary entries at three sightings. Never auto-applied.
5. **Dual-engine voting** — when Whisper's output is one edit from a vocabulary
   term, the Apple engine is run on the same clip and its word is taken ONLY
   where it matches the vocabulary and Whisper's does not.

## Claims to verify

1. **Nothing can insert a word the user did not say.** `DualEngineVoting` may
   only emit words one of the two engines produced at that position; different
   word counts are never merged; only a vocabulary-matching word can be
   substituted. `ShortUtteranceFastPath` only skips the LLM stage, never edits
   words. Two-phase refine derives both phases from the same `raw` under
   `CleanupGuard`.
2. **Prompt echo cannot reach the user.** `TranscriptSanity.looksLikePromptEcho`
   (≥4 words, ≥3 distinct prompt terms, ≥60% of content words from the prompt)
   routes an echoed decode to the Apple engine's transcript of the same audio, or
   discards it for the fallback. Attack BOTH directions: an echo that slips
   through (screen contents inserted into the user's field), and a false positive
   that eats real speech.
3. **Voting is scoped to the user's own vocabulary, not screen terms.** Screen
   terms bias the decoder and get no vote. Confirm no path passes
   `orderedTerms` into `containsNearMiss` or `reconcile`.
4. **The AX screen read cannot stall a dictation.** Every element gets a 0.25s
   messaging timeout (it binds per-object, not per-tree), the deadline is
   re-checked before every AX round-trip, and the walk runs on a dedicated
   serial queue rather than the Swift cooperative pool. The dictation never waits
   on it — `harvestedScreenTerms` polls a lock-guarded mailbox for 0.2s and gives
   up. Secure input, password managers and VoiceFlow itself are refused.
5. **Two-phase delivery cannot corrupt text or swallow the next utterance.** It
   is off by default. Phase two runs after `finishRecording` returns, is
   cancelled by the next `beginRecording`, and `replaceLastInsertion` re-proves
   the exact UTF-16 range immediately before writing, restoring a collapsed caret
   on any mismatch. It fails closed on an unknown origin app.
6. **Learning proposes, never mutates, and honours privacy switches.** Only
   name-shaped corrections (a capital or a dotted compound) are learnable; "Keep
   history" off disables the watcher entirely; Clear History wipes the learned
   words too.
7. **SQLite migration upgrades an existing user's DB.** Both the fresh
   `CREATE TABLE` and the two `ALTER TABLE ADD COLUMN`s put the new columns at
   ordinals 10/11, matching `readRow`'s positional reads.

## Attack specifically

- **Capture-file lifecycle** across three consumers (Whisper, the phantom
  arbiter, the voting arbiter, the Apple fallback): double-delete, leak, or a
  path reading a file another already deleted. The arbiter must be consulted at most
  once per dictation.
- **Rapid push-to-talk** (5 taps in 2s): a stale refinement or correction watcher
  from dictation N touching dictation N+1's field.
- **Cancellation** mid-transcribe, mid-cleanup, mid-arbiter: continuations
  resumed twice or never; the capture deleted underneath an in-flight finish.
- **Unresponsive frontmost app** during the AX harvest and during the correction
  watcher's reads — main-thread freezes, cooperative-pool starvation.
- **Prompt-echo false positives** on genuine speech that uses several vocabulary
  terms in one sentence.
- Anything in `539465b` that was fixed in the wrong place or only half-fixed.

## Accepted tradeoffs (do NOT flag)

- **CleanupGuard stays STRICT** — it rejects synonym-level rewrites and most
  grammar cleanup, so LLM cleanup is close to a punctuation pass. This is the
  user's standing verbatim-first decision, not an oversight.
- **English only.** `languageCode` plumbing is deliberately untouched; Hebrew is
  planned as a secondary language later.
- Lowercase jargon is not learnable as vocabulary (only name-shaped corrections
  are) — a deliberate false negative; a wrong entry rewrites real words forever.
- Product names mixing letters and digits ("H100") are not harvested from the
  screen — the same filter keeps 2FA codes and licence fragments out.
- The screen harvest snapshots the app that was frontmost at record START; if the
  user switches apps mid-hold the bias terms are from the previous window.
  Accuracy only, never correctness.
- Two-phase delivery is unproven in live use; it is off by default and flagged
  for a live session.
- The always-warm microphone (and its always-on macOS indicator) is pre-existing
  behavior on `main`, not part of this branch. An idle-timeout is queued as its
  own branch with the user present, per the never-change-audio-blind rule.
- `AppCoordinator.cancel()` is currently unreachable from the UI.

## Verdict format

PASS (safe to merge) or FAIL with blocking defects as `file:line` + a concrete
failure scenario + a suggested fix.
