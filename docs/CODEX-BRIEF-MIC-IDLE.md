# Codex Verification Brief — mic idle-release → main merge

Repo: github.com/johnny777boy/voiceflow
Branch to verify: `feature/mic-idle-timeout` (verify current HEAD)
Merge target: `main` (`ed0d2b5`, tag `verified-2026-08-09-upgrades`)
Diff: `git diff main...feature/mic-idle-timeout -- Sources/` (~120 insertions, 4 files)
Build/test: `swift build` and `swift build -c release` (both 0 warnings) ·
`swift run VoiceFlowTests` → "All 178 tests passed".
If your environment hits `sandbox-exec: sandbox_apply: Operation not permitted`,
re-run with `--disable-sandbox` (environment restriction, not a project defect;
its SwiftPM cache warnings are expected).

## Context

Small, focused branch. The always-warm `AVAudioEngine` (kept alive so the ~0.8s
pre-roll ring protects the first word) lit the macOS orange mic indicator 24/7.
This branch releases the engine 3 minutes after the last dictation and restarts
it at the next key-down. THIS IS THE AUDIO-CAPTURE PATH (CLAUDE.md rule 6): the
change was made with the owner present, and his live test PASSED — indicator
dark at ~3 minutes, engine restarted on the next dictation, first word intact.

Two internal reviewer agents (senior + adversarial concurrency) reviewed the
diff; NO Critical/Important findings. Their Minor/hardening findings are all
fixed in the branch HEAD:
- A throwing `startRecordingImpl` (or a stray stop while idle) exited with the
  timer cancelled and the engine warm — indicator lit forever. Failure paths now
  re-arm (`defer` in start; early-return re-arm in stop).
- Toggling the setting OFF while already released now re-warms immediately.
- A straggler tap callback could repopulate the pre-roll ring after release;
  a fresh engine now clears the ring before installing its tap.
- `scheduleIdleRelease` refuses to arm mid-capture (prewarm-during-dictation
  race); `releaseEngineIfIdle` nils the fired one-shot; `deinit` invalidates.

## Mechanics

- One-shot main-thread `Timer` (180s, 10s tolerance), armed at
  `stopRecordingImpl`/`prewarm`, cancelled at `startRecordingImpl`. Firing runs
  `releaseEngineIfIdle` (main thread): guard `!isRecording` → `removeTap` →
  `engine.stop()` → `engine = nil` → clear pre-roll under the lock.
- Every mutation of `engine`/`idleTimer`/`isRecording` is main-thread-confined
  (`onMain` / `onMainAsync` / `RunLoop.main`); the render-thread tap touches only
  `recording`/`audioFile`/`preroll` under `lock`. Nothing pumps the run loop
  inside these blocks, so the timer cannot interleave INSIDE them.
- New `AppSettings.micIdleReleaseEnabled` (default true), synthesized
  CodingKeys + `decodeIfPresent` fallback, wired at coordinator init and
  `applySettings`, SettingsView toggle in General.

## Claims to verify

1. **The one invariant: no interleaving may produce a dictation where the user
   speaks and audio is silently not captured.** The internal adversarial pass
   proved: engine-exists-without-tap, recording-without-tap, and file-open-with-
   engine-stopped each require the timer to fire inside a synchronous
   main-thread block, which the run loop cannot do. Attack this proof.
2. **A release can never sever a live capture**: `releaseEngineIfIdle` guards the
   main-confined `isRecording`, which is true for the whole dictation span
   including the 0.18s drain; the timer is cancelled for that whole span anyway.
3. **Failure paths cannot strand the indicator**: any exit from
   `startRecordingImpl` (throw at engine start, unopenable capture file) and the
   not-recording early return of `stopRecordingImpl` re-arm the countdown when
   an engine exists.
4. **Cold start after idle is correct**: `startEngineIfNeeded` builds a fresh
   engine, re-reads the CURRENT device format into `tapFormat`/`prerollFrameLimit`
   (a device change during the idle gap is picked up), clears the pre-roll ring
   before installing the tap, and publishes `engine` only after `start()`
   succeeds. A failed start surfaces as a visible "Mic error" overlay, never
   silence.
5. **Settings round-trip**: old `settings.json` without the key decodes to
   default true; toggle takes effect immediately in BOTH directions (on-while-
   idle arms now; off-while-released re-warms now).
6. **No behavior change outside the stated scope**: tap callback body, formats,
   pre-roll sizing, drain, capture-file lifecycle, and all transcribe paths are
   untouched by this diff.

## Attack specifically

- The timer firing in the actor-hop window between hotkey key-down and
  `startRecordingImpl` (main thread released at `await controller.beginRecording()`
  and at the permission check). Internal verdict: possible but bounded — worst
  case is a cold start (no pre-roll), never a torn capture. Try to make it worse.
- Rapid sequences: press at exactly T+180s; ESC-cancel storms; toggle flapping
  in Settings while dictating; sleep/wake across the countdown.
- `deinit`/lifecycle of the block-based timer; double-arm; arm-while-recording.
- Whether `try? startEngineIfNeeded()` in the didSet OFF branch can throw in a
  state where the user believes always-warm is restored but the engine is dead
  (and whether that failure is visible or silent).

## Accepted tradeoffs (do NOT flag)

- The FIRST dictation after an idle release cold-starts: no pre-press pre-roll,
  so speaking at the exact instant of key-press can clip the opening. This is
  the entire, explicitly accepted price of the feature; the owner tested it live
  and took it. The Settings toggle restores always-warm for users who won't.
- `prewarm()` on every app activation / wake re-lights the indicator for 3
  minutes with no dictation intent (activity predicts dictation), and resets the
  countdown on each activation.
- A ~few-ms timer-vs-keypress window at exactly T+180s costs a cold start (see
  attack list) — accepted; a synchronous `noteActivity()` from the hotkey path
  was considered and deferred as not worth new cross-thread surface.
- No unit tests for this class: the test target links VoiceFlowCore only (no
  XCTest on this machine — Command Line Tools only); the audio path is verified
  by review + live test per the project's standing workflow.
- CPU of the warm engine is ~0.1% measured; the feature exists for the
  indicator light and battery, not performance.

## Verdict format

PASS (safe to merge) or FAIL with blocking defects as `file:line` + a concrete
failure scenario (exact interleaving for races) + a suggested fix.
