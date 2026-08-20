# Codex Verification Brief — accuracy parity branch → main

Repo: github.com/johnny777boy/voiceflow
Branch: `feature/accuracy-parity` (head `0af7359` or later — verify actual HEAD)
Merge target: `main` (`9efd3cb`, tag `verified-2026-08-10-mic-idle`)
Diff: `git diff main...HEAD -- Sources/ Scripts/ Package.swift`
(50 commits, ~3.6k insertions, 43 files. The earlier branch
`feature/latency-instrumentation` is folded in — its own brief is
`docs/CODEX-BRIEF-RECOVERY.md`; findings there still apply.)

Build: `swift build -c release --product VoiceFlow` → 0 warnings.
Tests: `swift run VoiceFlowTests` → "All 213 tests passed".

**Known non-defect, do NOT report:** a BARE `swift build` fails inside
WhisperKit 1.1.0's vendored `TTSKit` module (unused by this app, fails Swift 6
strict concurrency). Build named products instead; `build_app.sh` already does.

---

## What this app is, and the one rule that outranks everything

macOS push-to-talk dictation, fully on-device. The owner is a **non-native
English speaker**. The inviolable product rule: **never change what the user
said.** Cleanup may fix grammar and punctuation; it may never add, drop, or
swap a word. The competitor this is benchmarked against shipped an AI cleanup
that changed users' words and drew 700+ complaints — `CleanupGuard` exists to
make that impossible, and it is the product's main advantage.

## The decision this review protects

Two defaults are about to be changed **on the strength of numbers this branch's
new tooling produces**:

1. speech model `openai_whisper-large-v3-v20240930_turbo` → full
   `openai_whisper-large-v3-v20240930`;
2. context biasing on (vocabulary fed to the recognizer before decoding).

**If the measurement lies, the team ships a slower and/or worse app believing it
is better.** This project has already been burned twice by plausible-but-wrong
results: a dead Whisper engine went unnoticed for 8 days, and a source comment
named a *turbo* build as "full large-v3", so the planned A/B would have compared
turbo with turbo and "cleared" the model. **Treat the measurement code as
safety-critical, equal to the guard.**

## Claims to verify

1. **WhisperKit 0.18.0 → 1.1.0 changed nothing but the typo.** The only source
   edit was `supressTokens` → `suppressTokens`. Verify no silent semantic change
   in decode options, chunking, temperature fallback, suppress-token
   construction, the silence arbiter, or the capture-file lifecycle. (Upstream
   PR #514 also changed prompt/prefill handling and bounds-checked
   `MLMultiArray.fill()` for `suppressTokens: [-1]` — confirm our usage is
   correct under the new behaviour.)
2. **The Whisper move is behaviour-preserving.** `WhisperKitTranscriber` /
   `WhisperModelManager` moved from the app executable into a new
   `VoiceFlowWhisper` library so `VoiceFlowBench` can drive the PRODUCTION
   decoder. Many members widened `internal` → `public`. Verify nothing dangerous
   is now reachable and no invariant depended on the old access level.
3. **Audio never lingers.** `retainCaptureFile` / `captureArchiveDirectory` exist
   only for benchmarking. Verify that with `benchmarkRetainCaptures` unset,
   behaviour is byte-identical to before (capture deleted on success), and that
   nothing can leave audio on disk — or off-device — in normal use.
4. **`CleanupGuard.rejection()` refactor is behaviour-preserving.**
   `preservesMeaning` is now `rejection(...) == nil`. All 203 pre-existing tests
   pass untouched, so ANY behaviour change is a defect, not a policy change.
5. **`severedClause` is sound.** New rule: cleanup may not invent a sentence
   boundary that starts on a backward-binding word (before/until/because/if/
   that/which) or leaves the previous sentence dangling on a function word.
   Motivating live defect: "call me before the meeting we can decide then" →
   "Call me. Before the meeting…" was ACCEPTED, turning a conditional
   instruction unconditional.
6. **`sharesStem` rewrite.** Short stems must GROW BY AN INFLECTION (with
   consonant doubling); 1-2 letter stems are never stems; `n't` contraction
   heads are allowed only when the base word was actually spoken. Motivating
   defect: "we need to dig a new well" → "…a new" was ACCEPTED because "we"
   prefixes "well".
7. **The cleanup audit cannot misattribute.** `CleanupAuditLog` is a one-slot
   lock-protected mailbox: the provider writes the precise verdict with
   `record`, the pipeline writes coarse outcomes with `recordIfAbsent`, the
   controller takes it before AND after the cleanup call and copies it onto the
   history record (3 new SQLite columns, appended).
8. **Biasing cannot corrupt the transcript.** Ships OFF behind
   `whisperPromptBiasingEnabled`. `TranscriptionContext.promptText` now emits a
   natural sentence (lead-in + terms + trailer) instead of a comma list, because
   the list's Capitalised style was measurably bleeding into transcripts.
9. **`PhoneticVocabulary` is detection-only.** It proposes vocabulary entries and
   must never substitute text anywhere.

## ATTACK SPECIFICALLY — the measurement (highest value)

- **Pairing.** `wer_compare.py` pairs hypothesis line N with reference line N;
  `VoiceFlowBench` sorts capture files by filename (`capture-<millis>.wav`).
  Find every way that order desynchronizes: same-millisecond captures, zero-pad
  width, a failed/empty dictation, a re-read line, a skipped line, stale files,
  `.DS_Store`. A silent off-by-one misaligns EVERY pair and yields a confident
  wrong WER.
- **Statistical power.** The read reference is 50 utterances / ~604 words.
  Compute what effect size a paired bootstrap can actually resolve at that size
  and state plainly whether the ~1-WER-point model decision is answerable at
  all. **If it is not, that is the most important finding in this review.**
- **Normalization bias.** `wer_compare.py` folds spoken numbers to digits.
  Verify it applies identically to both hypothesis files and cannot favour
  either; check "one hundred", "twelve hundred", "fifteenth", "four oh three",
  which all appear in the reference. Check entity recall against multi-word
  entities ("Payload CMS", "VS Code", "Next.js") — tokenization must match how
  they appear in hypotheses, and the multiset counting must not double-count.
- **Is it the same program twice?** Verify both runs use identical decode
  options, suppress tokens, arbiter behaviour and preprocessing, so the only
  difference is the variable under test. Can a variant string silently resolve
  to a different model, or fall back without saying so?
- **Latency honesty.** Decode timings are wall-clock and include first-load
  effects. Is the reported mean misleading?

## Accepted tradeoffs (do NOT flag)

- Biasing and the full model both ship OFF/unchanged pending WER on the owner's
  voice. "Works" is deliberately not "better".
- `PhoneticVocabulary` will produce some false SUGGESTIONS. Accepted: a false
  suggestion costs one dismissal; a false substitution destroys a word he said,
  which is why it never substitutes. "codecs"/"codices" are real English words —
  no text-level rule can disambiguate them, and that is stated in the code.
- The cleanup audit stores a third copy of each dictation locally
  (`cleanupProposed`), under the same retention limit and Clear History.
- `AppSettings.privacyRedactionEnabled` is wired to nothing — a known
  pre-existing defect, tracked separately. Do not spend the round on it.
- Test coverage cannot reach app-target UI/engine classes (Command Line Tools,
  no XCTest); those rest on review plus live use.

## What this review CANNOT establish

Whether transcription accuracy equals the owner's reference product. That
requires his voice and a WER run. Please do not opine on it — instead, make sure
the machinery that will answer it cannot lie.

## Verdict format

PASS (safe to merge) or FAIL with blocking defects as `file:line` + a concrete
failure scenario (exact interleaving for races) + a suggested fix.
