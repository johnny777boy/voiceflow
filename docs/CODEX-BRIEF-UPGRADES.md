# Codex Verification Brief — upgrades Phases 1–5 → main merge

Repo: github.com/johnny777boy/voiceflow
Branch to verify: `feature/upgrades-phase1-5` (head `539465b` — verify whatever HEAD is when you start)
Merge target: `main` (`7b8f8fd`)
Diff: `git diff 7b8f8fd...HEAD -- Sources/`
Build/test: `swift build` and `swift build -c release` (both 0 warnings) ·
`swift run VoiceFlowTests` → "All 173 tests passed".
If your environment fails these with `sandbox-exec: sandbox_apply: Operation not
permitted`, re-run with `--disable-sandbox` (that is an environment restriction,
not a project defect — the SwiftPM cache warnings it prints are expected too).

macOS 26, SwiftPM, Command Line Tools only — there is no Xcode and no XCTest on
this machine. The suite is a plain executable target; that is deliberate, not a
gap to flag.

## Round 7 — what changed since your round-6 FAIL

You FAILed the tokenizer's symmetric trim:

> `corroborationTokens` strips `.` from both ends, so ".NET" collapses into "net"
> and an echoed ".NET" is corroborated by an arbiter that only said "NET".

Fixed with an asymmetric trim: trailing edge punctuation is still stripped (a
trailing dot in prose is overwhelmingly the sentence period), but a LEADING `.`
followed by a letter or digit is kept as part of the word (".NET", ".env").
Your two suggested cases are pinned as tests — `.NET` vs `NET` rejects,
quoted/trailing `".NET."` vs `.net` corroborates — plus the sentence-boundary
pair.

**Your ruling on the open question is adopted and recorded**: no confidence or
energy gate on `looksLikePromptEcho` — prompt continuation can be confident, and
audible audio does not prove the emitted terms came from speech. The defense
stays unconditional; the false-positive cost (an extra arbiter run on
vocabulary-dense sentences, and the lose-a-word-not-insert-one preference when
engines disagree) is accepted as the price of the invariant. If that cost proves
too high in live use, the text heuristic or corroboration policy gets tightened —
never gated on doubt signals. Recorded in the backlog as a settled decision.

178 tests, 0 warnings.

## Round 6 — what changed since your round-5 FAIL

You FAILed corroboration on tokenization:

> It reused `normalized`, which strips all punctuation, so "C++" and "C" collapse
> to the same token — an echoed "C++" counted as corroborated by an arbiter that
> only said "C", and the symbols were delivered.

Correct. Corroboration now has its own tokenizer, `corroborationTokens`: case-fold,
strip only the punctuation SURROUNDING a word (sentence periods, commas, quotes,
brackets), keep everything inside it. "C++", "C#" and "Next.js" no longer
corroborate "C" or "next". `normalized` is unchanged and still used for phantom
phrase matching, where stripping is correct. Five tests, including the identical
symbol-bearing pair that must still pass.

177 tests, 0 warnings.

### OPEN QUESTION for you — detection fires on this user's ordinary speech

Not a defect I can prove, but a design problem your review should weigh in on.
`looksLikePromptEcho` needs ≥4 words, ≥3 distinct prompt terms, ≥60% prompt words.
This user's vocabulary is `Payload CMS, Next.js, PostgreSQL, TypeScript, GitHub,
VS Code, Claude Code, Codex, …`. Worked example: **"Payload CMS and Next.js"**
normalizes to 4 words, 3 of them prompt terms ⇒ 0.75 ⇒ **flagged as an echo**.
That is a sentence he would genuinely say.

Consequences when it misfires on real speech: an extra full Apple transcription
(~1–2s, on a build whose measured median release-to-insert is already ~2.1s
against a 1.5s target), and — if the engines differ at all — his text comes from
the Apple engine instead of Whisper, which is the weaker engine on his accent.
The feature meant to protect vocabulary-heavy dictation would degrade exactly it.

The obvious tightening is to require a corroborating doubt signal, since echoes
come from low-information audio: both `minAvgLogProb` and near-silence `maxRMS`
are already computed at the call site. I have NOT applied it — it weakens a
defense you have already FAILed me on four times, and that call should not be
made unilaterally at this depth. Tell me whether you consider the confidence gate
safe, or whether the latency/accuracy cost is the correct price.

## Round 5 — what changed since your round-4 FAIL

You FAILed the exact-corroboration rule on the one thing it still approximated:

> `isFullyCorroborated` used `Set`, so it corroborated word TYPES, not
> occurrences. Whisper produces "Sarah Kubernetes Grafana Sarah", the arbiter
> hears "Sarah Kubernetes Grafana" — identical sets — so the repeated name was
> delivered though the arbiter never said it twice.

Correct, and it is the same class of error as the previous three: a comparison
that is *almost* the property. Now a multiset check — every token in the suspected
transcript must be spent against a matching token in the arbiter's, so a word
appearing twice must have been heard twice. Two tests: the repeat case rejects,
genuine repetition (heard twice) still passes.

176 tests, 0 warnings.

## Round 4 — what changed since your round-3 FAIL

You confirmed the capture-ownership fix and found no other lifecycle path, then
FAILed the `>= 0.5` agreement threshold:

> User says "Sarah Kubernetes Grafana"; Whisper echoes "Sarah Kubernetes Payload
> CMS Grafana"; the arbiter hears the three real words. 3/5 = 0.6 clears the
> threshold and "Payload CMS" is inserted — words neither the user nor the arbiter
> produced.

Correct, and it is the third hole in a row in this one decision. The pattern is
the point: every version was a similarity SCORE, and partial agreement is exactly
the shape of a partial echo, so no threshold can separate them. Rather than raise
it to 0.8 I replaced the scoring with the exact property the code actually needs:

**`TranscriptSanity.isFullyCorroborated(text, by: other)`** — Whisper's text is
delivered only if EVERY word in it also appears in the arbiter's transcript.
Otherwise the arbiter's transcript is delivered. There is no threshold left to
tune, and no partial case to construct: one uncorroborated word is enough to
reject. `wordOverlap` is deleted (zero references remain).

Accepted cost, unchanged in principle but now more often paid: when the engines
differ on any word we take the arbiter's transcript, which can lose a better
spelling Whisper had (its "Sarah" against the arbiter's "Sara"). Losing a word
beats inserting one. A test pins that specific trade so nobody "fixes" it later.

175 tests, 0 warnings.

## Round 3 — what changed since your round-2 FAIL

You confirmed the capture-ownership fix, then returned **FAIL** on the agreement
check I had added to make echo false-positives harmless. You were right again:

> `TranscriptSanity.swift:124` — `wordOverlap` divides by the shorter transcript's
> distinct word count, so a subset match looks like full agreement. User says only
> "Sarah"; Whisper echoes "Sarah Kubernetes Payload CMS Grafana"; the arbiter
> correctly hears "Sarah"; overlap returns 1.0, echo suspicion is cleared, and the
> full echo is delivered.

**Fix:** `wordOverlap` now divides by `max(a.count, b.count)`, so both transcripts
must be substantially covered and text only ONE engine produced always counts
against agreement. The failure scenario now scores 0.2 and is correctly treated as
an echo. Two regression tests pin it, including the argument-order-swapped case.

Consequence worth attacking: when the engines genuinely disagree the caller now
prefers the arbiter (the engine with no prompt to echo), which can mean dropping a
word the other engine heard — e.g. if the Apple engine under-transcribes. That
asymmetry is deliberate and matches the product rule (inserting words the user
never said is unacceptable; losing one is not), but tell me if you can construct a
realistic case where it costs real speech often enough to matter.

174 tests, 0 warnings.

## Round 2 — what changed since your round-1 FAIL

You returned **FAIL** on round 1 (`fab60de`) with one blocking defect, and you
were right:

> `WhisperKitTranscriber.swift:229` — prompt-echo recovery can lose real speech
> when the Apple arbiter consumes the only capture file and then becomes
> unavailable.

Confirmed exactly as described: `SpeechAnalyzerDictation.transcribe` took the
recorder's shared `fileURL` and deleted it in a `defer` that runs even when the
method throws later (a failed model install), so `.unavailable` left the fallback
with nothing to read. The echo path I added throws on `.unavailable` — unlike the
pre-existing phantom path, which falls through — so the defect was introduced by
the echo fix itself.

**Fix (your first suggestion, capture ownership made explicit):**
- `consultArbiter` now copies the `.caf` to a private temp file and hands the
  arbiter the copy. The arbiter deletes only that copy; the original survives
  every arbiter outcome, and the caller decides when to consume it.
- `SpeechAnalyzerDictation.transcribe` now consumes `audio.fileURL` (the capture
  it was handed) rather than the recorder's shared slot, falling back to
  `takeFileURL()` only when it was given nothing.
- The `FallbackTranscriber` comment that documented the old "the arbiter may have
  already consumed the file" behavior was wrong and is corrected.

**Your second point (tightening echo detection so vocabulary-dense speech does
not enter this path as readily)** is addressed differently — by making a false
positive harmless rather than rarer, since the text-only signal cannot separate
"Sarah Kubernetes Payload CMS Grafana" from an echo of those same terms. On
`.heard`, the two transcripts are compared (`TranscriptSanity.wordOverlap`): the
second engine had no prompt to echo, so agreement ≥ 0.5 means the user really
said it and **Whisper's text is kept** (it is the better engine on this user's
accent); only genuine disagreement substitutes the arbiter's transcript. Please
attack this specifically.

Head is now `HEAD` of the branch; 173 tests, 0 warnings.

**Note on testing this area:** the test target links `VoiceFlowCore` only, so
`WhisperKitTranscriber` / `SpeechAnalyzerDictation` (both in the app target) have
no unit coverage — the capture-ownership invariant is enforced by code and review,
not by a test. That is a pre-existing structural limitation of this package
layout, not something introduced here. Flag it if you think it is blocking.

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

- **Capture-file lifecycle** across every consumer (Whisper, the phantom arbiter,
  the echo arbiter, the voting arbiter, the Apple fallback): double-delete, leak,
  or a path reading a file another already deleted. The invariant to break: **the
  original capture survives until Whisper succeeds, and the fallback can always
  re-read it.** The arbiter must be consulted at most once per dictation.
- **The round-1 defect's neighbours**: any other place where a failure path
  destroys state a later recovery depends on.
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
