# Codex Verification Brief — engine recovery + instrumentation → main merge

Repo: github.com/johnny777boy/voiceflow
Branch to verify: `feature/latency-instrumentation` (head `bea6ce1` — verify
whatever HEAD is when you start)
Merge target: `main` (`9efd3cb`, tag `verified-2026-08-10-mic-idle`)
Diff: `git diff main...HEAD -- Sources/`
Build/test: `swift build` and `swift build -c release` (both 0 warnings) ·
`swift run VoiceFlowTests` → "All 207 tests passed".

**ROUND 3.** Round 1 passed on capture ownership. Round 2 FAILED — reordering
pronouns reversed a debt ("you owe me and I owe you" → "you owe you and I owe
me") because the guard compared word SETS; fixed in `a8cbd06` with an
order-aware LCS check, which you should re-attack. Everything in the section
below landed AFTER round 2 and has had no external review at all.
If your environment hits `sandbox-exec: sandbox_apply: Operation not permitted`,
re-run with `--disable-sandbox` (environment restriction, not a project defect).


## ⚠️ THREE COMMITS LANDED AFTER THE INTERNAL REVIEW — look hardest here

Both internal reviewer agents reviewed through `6d3d937`. These came after, so
they carry NO internal review and need your full attention:

**`9776c78` — the short-utterance fast path was discarding real grammar repairs.**
The owner reported the recognizer writing "You'll finish everything." for "you
finished everything?". I first blamed `CleanupGuard`; that was wrong, and two new
tests pin the truth: the guard PERMITS that repair ("finished" shares a stem with
"finish"; the contraction shard "ll" is not a content word), while
`ShortUtteranceFastPath.canSkipLLM` returned true for the utterance (6 words,
statement, cleanWriting), so the LLM pass never ran. The fast path's own safety
argument was false — it assumed the strict guard reduced the model to a
punctuation pass, making the skip free. Consequences to verify: `fastShortUtterances`
now defaults **false**; the doc comments and Settings copy were corrected; the
setting still works in both directions; the decode path is otherwise untouched.
**Attack:** does defaulting it off change anything besides "the LLM pass now runs
on short utterances"? Does any test or behaviour still assume the old default?

**`d50a787` — install/rollback scripts + cleanup diagnostics.**
`Scripts/install_app.sh` archives the app it replaces (last 5, commit-stamped);
`Scripts/rollback_app.sh` restores one (bash 3.2 compatible — no mapfile). These
touch no product code. Also: `FoundationModelsCleanupProvider` now logs three
previously-indistinguishable failures separately (model unavailable / empty
output / **guard rejected the edit**) — all three still throw the same error, so
control flow is unchanged; only logging was added. **Attack:** does the new
`.private` debug line risk leaking transcript content at any log level? Do the
scripts have a path that could destroy `/Applications/VoiceFlow.app` without a
usable archive existing first?

**Open, deliberately not fixed here (do not flag as defects):** the on-device
cleanup model's repairs appear to be rejected wholesale by the all-or-nothing
guard — a single disliked change discards every punctuation and grammar fix
bundled with it. The diagnostics in `d50a787` exist to confirm that from live
logs before any guard redesign is attempted. A per-edit guard is the intended
follow-up, on its own branch, WER-gated.

## NEW SINCE ROUND 2 — the cleanup-fidelity work (no external review yet)

**`8b46384` + `7a470cb` — the model was REFUSING his dictations.** Handed a bare
transcript, Apple's on-device model reads second-person speech as a message
addressed to it and replies "I'm sorry, but I cannot help you with that" (3/3
runs, measured on his Mac); another dictation made it emit a whole change-order
letter. Fixed by delimiting the transcript (`<<<TRANSCRIPT … TRANSCRIPT>>>`) and
instructing the model that it is a text filter, never an addressee — the framing
every product that solved this converged on. **Attack:** can any transcript
content escape the delimiters or re-address the model (a transcript that itself
contains `TRANSCRIPT>>>`, or instructions like "ignore the above")? The guard is
the backstop — verify that a model reply which is NOT a cleanup of the input
(refusal, letter, commentary) is always rejected rather than delivered.

**`08b14c5` — `sharesStem`: a prefix is not a stem.** THIS REPLACES THE RULE ANY
EARLIER BRIEF DESCRIBED. Old rule: for words ≤4 chars, any prefix relation meant
"same stem". That forgave DELETING or INVENTING a whole content word whenever
some short unrelated word prefixed it — "we need to dig a new well" → "we need
to dig a new" was ACCEPTED under both policies, because "we" prefixes "well".
The partners are the words in every sentence (`we/well`, `we/went`, `it/item`,
`in/into`, `at/attic`, `be/beam`, `do/door`, `us/used`, `the/there`, `an/and`).

New rule (`CleanupGuard.isInflection`): a short stem must GROW BY AN INFLECTION —
`s/es/ed/ing/er/est/ly`, plus `d/r/st` only on a stem already ending in "e", plus
final-consonant doubling (`stop`→`stopped`); and a stem of 1-2 letters is never a
stem (verb forms that short are irregular, and `sameIrregularVerb` covers them).
**Attack:** find a pair the new rule still forgives where the two words are NOT
morphologically related, especially one where both plausibly occur in the same
dictation. A dictionary audit found only an "-er" tail (`corn/corner`,
`off/offer`, `cent/center`) — deliberately left, because tightening it rejects
`own`→`owner` and `low`→`lower`. Also verify the converse: that a legitimate
non-native repair is not now rejected (the suite pins `ask`→`asked`,
`use`→`used`, `work`→`working`, `stop`→`stopped`, `ship`→`shipped`).

**`08b14c5` — contraction heads.** `"do not touch it"` → `"Don't touch it."` had
been passing only because "do" prefixed the unspoken token "don" that `allWords`
splits out of "don't". That accident is now an explicit rule: an `n't` head is
forgiven only when it is `<a word actually spoken> + "n"`. **Attack:** can a
head-shaped token smuggle in a word the user never said (possessives, `won't`
from "will not", curly apostrophes, an apostrophe at position 0)?

**`bea6ce1` — the cleanup audit.** `CleanupGuard.rejection()` is now the single
source of truth and `preservesMeaning` is literally `rejection(...) == nil`, so
the audit can never report a verdict different from the one the guard took.
History gains three columns (`cleanupProposed`, `cleanupDecision`,
`cleanupRejectReason`) recording what the model proposed and what became of it.
Motivation: 21 of 28 real dictations delivered text byte-identical to the raw
transcript, and that is indistinguishable between "nothing to fix" and "the
guard silently reverted everything".

**Attack this ordering specifically:** a guard rejection reaches the pipeline as
a thrown `cleanupProviderUnavailable`, i.e. the SAME error as "Apple
Intelligence unavailable". The provider writes the precise verdict with
`record`, the pipeline writes coarse outcomes with `recordIfAbsent`. Show a path
where the coarse outcome overwrites the precise one, where an entry from
dictation N is attributed to dictation N+1 (the controller takes the slot before
AND after the cleanup call; two-phase delivery runs a SECOND cleanup after the
record is saved), or where `CleanupAuditLog`'s lock is insufficient.

**Also verify:** the refactor of `preservesMeaning` into `rejection` is
behaviour-preserving — every one of the 203 pre-existing tests passes untouched,
so any behaviour change would be a defect, not a policy change.

## Why this branch exists — a lived, week-long silent failure

The owner reported "sometimes it's not that great". The instrumentation in this
branch answered why: **High Accuracy was ON, the 1.5 GB model was on disk, and
every dictation for 8+ days silently ran on the fallback Apple engine.** No
error, anywhere. Chain, established by live A/B with the owner dictating:

1. (Latent, fixed) The load-time `WhisperKitConfig` set only `modelFolder`.
   WhisperKit resolves its tokenizer via `tokenizerFolder ?? downloadBase`, so
   with neither set it used the library default — `~/Documents/huggingface` —
   which is TCC-protected for this app. Now both are pinned to App Support.
2. (The killer, HOTFIXED) Feeding `promptTokens` makes WhisperKit 0.18 decode
   EVERY clip to zero characters → `emptyTranscript` → silent Apple fallback.
   Proven both directions live. Prompt biasing is therefore DISABLED behind
   `UserDefaults` key `whisperPromptBiasingEnabled` (ships false), and the
   prompt-echo defense is gated on a prompt actually having been fed. The root
   cause inside WhisperKit is NOT yet isolated — that is deliberate follow-up
   work, gated on a WER test, per the owner's standing rule that speed/features
   may never cost quality.
3. (Prevention) A load watchdog + a main-window banner so this class of failure
   can never again be silent.

Two internal reviewer agents (senior + adversarial) already reviewed this diff;
their findings are fixed in `6d3d937` — see that commit message.

## Claims to verify

1. **The hotfix is behaviorally exact.** With the flag false the ONLY delta from
   the pre-hotfix path is: no `promptTokens` fed, and no echo check run. With it
   true, the path is the pre-hotfix path. Nothing else — energy gate, suppress
   tokens, phantom arbiter, voting, capture-file lifecycle — changed.
2. **The watchdog can never kill a healthy load.** It is armed ONLY inside
   `run()` at the moment the load phase begins (reached by both the cached and
   post-download paths); the earlier `ensureReady` arm site was deleted
   precisely because it fired mid-load after a fast download. Verify no path
   arms it before `.preparing`, and that a fired watchdog cannot adopt/overwrite
   a completed pipeline (`isCurrent` generation guards).
3. **No concurrent double-load.** After a watchdog fire, `task` stays set so
   `ensureReady`'s `task == nil` guard refuses a second 1.5 GB load; only
   `retry()` deliberately drops it.
4. **Atomic history updates.** `setEditedAfterInsert` / `updateCleanText` are
   single UPDATE statements under the store lock, not read-modify-write, so the
   correction watcher and two-phase refinement cannot clobber each other.
5. **SQLite migration is positionally safe.** Columns are only ever APPENDED
   (ordinals 12–15 for the timings, 16–18 for the cleanup audit); `readRow`
   guards on `sqlite3_column_count`; a real 12-column legacy database is built
   and migrated in the test suite. Verify a row written by the NEW binary is
   still readable by the old one, and that the audit columns default to NULL.
6. **Instrumentation is inert.** `engineName`/`decodeSeconds`/`arbiterSeconds`
   are diagnostic only — verify nothing branches on them.
7. **Audio-capture path untouched** (tap/preroll/formats/drain).

## Attack specifically

- The watchdog's generation arithmetic against toggle-off, rapid flapping,
  `retry()`, and a load completing within milliseconds of the deadline.
- Any path where the disabled prompt changes transcript CONTENT rather than
  just skipping the prompt (verbatim fidelity is the inviolable rule).
- The atomic UPDATEs vs `trim()` deleting a row mid-update, and old-binary
  compatibility of the 16-column rows.
- Whether the banner can ever claim "not running" while Whisper IS serving
  dictations, or stay silent while it is not (the failure it exists to prevent).
- The guard as a whole, adversarially: construct an edit that changes what the
  user SAID and still passes `preservesMeaning` under `.grammarRepair`. Money,
  dates, obligation, and who-owes-whom are the classes that matter. Round 2
  found one of these; assume more exist.

## Accepted tradeoffs (do NOT flag)

- **Context biasing is dormant** — Phase 1's headline feature is off because it
  provably breaks decoding. Whisper without biasing beats Apple with it; the
  accuracy floor comes first. Re-enabling is gated on root cause + WER proof.
- The echo defense is dormant with it (nothing to echo). Its unconditional
  ruling still stands for when the prompt returns.
- An emptied field (user sent before the 6s correction window) now counts as
  neither an edit nor a correction — a mild optimistic bias in the zero-edit
  metric, deliberately chosen over punishing every quick send.
- Fallback-path attribution: when Whisper fails and Apple re-runs, the record
  reads "apple" and Whisper's wasted decode folds into that number. Known,
  follow-up sized, totals remain correct.
- `decodeSeconds` is populated but not persisted (spare diagnostic).
- The cleanup audit stores a THIRD copy of the dictation text
  (`cleanupProposed`) in the same local database, under the same retention limit
  and the same Clear History. Deliberate: it is the only way to answer "did the
  guard throw away the polish?". (`AppSettings.privacyRedactionEnabled` is wired
  to nothing — a known, pre-existing defect, tracked separately. Do not spend
  the round on it.)
- The guard is now slightly STRICTER than the build the owner used yesterday, so
  a few edits that used to pass now fall back to the rule-based result. That
  direction is the standing rule (verbatim fidelity outranks polish).
- The legacy macOS <26 engine reports no engine name (irrelevant on target).
- No unit tests for the app-target engine classes: the test target links
  VoiceFlowCore only (Command Line Tools, no XCTest) — a pre-existing structural
  limit; those paths rest on review + live testing.

## Verdict format

PASS (safe to merge) or FAIL with blocking defects as `file:line` + a concrete
failure scenario (exact interleaving for races) + a suggested fix.
