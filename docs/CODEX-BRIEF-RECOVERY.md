# Codex Verification Brief — engine recovery + instrumentation → main merge

Repo: github.com/johnny777boy/voiceflow
Branch to verify: `feature/latency-instrumentation` (head `6d3d937`)
Merge target: `main` (`9efd3cb`, tag `verified-2026-08-10-mic-idle`)
Diff: `git diff main...HEAD -- Sources/`
Build/test: `swift build` and `swift build -c release` (both 0 warnings) ·
`swift run VoiceFlowTests` → "All 181 tests passed".
If your environment hits `sandbox-exec: sandbox_apply: Operation not permitted`,
re-run with `--disable-sandbox` (environment restriction, not a project defect).

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
5. **SQLite migration is positionally safe.** Four columns appended (ordinals
   12–15); `readRow` guards on `sqlite3_column_count`; a real 12-column legacy
   database is built and migrated in the test suite.
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
- The legacy macOS <26 engine reports no engine name (irrelevant on target).
- No unit tests for the app-target engine classes: the test target links
  VoiceFlowCore only (Command Line Tools, no XCTest) — a pre-existing structural
  limit; those paths rest on review + live testing.

## Verdict format

PASS (safe to merge) or FAIL with blocking defects as `file:line` + a concrete
failure scenario (exact interleaving for races) + a suggested fix.
