# Codex Verification Brief — formatting/verbatim branch → main merge

Repo: github.com/johnny777boy/voiceflow
Branch: `fix/consistent-chat-formatting` (verify current HEAD)
Merge target: `main` (`be50502`)
Diff: `git diff be50502..HEAD -- Sources/ CLAUDE.md docs/ROADMAP.md`
Build/test: `swift build` (0 warnings) · `swift run VoiceFlowTests` → "All 106 tests passed".

## Context
Follow-up branch to the already-merged Whisper work. Driven by live user testing
the same day; every change answers a defect the user personally hit. An internal
two-agent review round runs in parallel with your verification; final HEAD may
include its fixes (verify whatever HEAD is when you start).

## Claims to verify

1. **Uniform formatting policy** — no app defaults to code mode anymore.
   `PerAppBehavior.defaults` keeps only Mail→email; `AppSettings.autoMode`
   returns email for mail apps, cleanWriting for everything else (terminals and
   editors included). Code mode is reachable ONLY via an explicit per-app rule.
   Same speech ⇒ same formatted text in every text box.
2. **Phantom defense v2 (the "Thank you." killer)** — in WhisperKitTranscriber:
   ANY ≤4-word output from a ≤3s clip, plus any whole-output match of the
   expanded `TranscriptSanity.phantomPhrases` family, is routed through a
   second-opinion arbiter (the Apple engine, `silenceArbiter`, wired in
   AppCoordinator). Arbiter hears words ⇒ Whisper's text is delivered; arbiter
   throws ⇒ candidate discarded as hallucination. Real short utterances must
   NEVER be eaten (the user's live "Okay, let's test this." passed through).
   Fallback when no arbiter: previous corroboration filter.
3. **Bidirectional CleanupGuard** — LLM cleanup can no longer ADD any word
   (short-word exemption removed; live defect: 'Thank'→'Thank you.') nor DELETE
   significant words (live defect: leading clause dropped). Morphological
   variants pass (go→going, discuss→discussing); 1-char contraction shards and
   digits exempt; hesitation fillers deletable. ACCEPTED POLICY: legitimate
   synonym rewrites are rejected (falls back to rule-cleaned text) — do not flag.
4. **Continuation gaps in AX-blind fields** — AccessibilityTextInserter tier-2:
   when the caret can't be read (web/Electron), a same-app insertion within 120s
   whose payload ended in non-whitespace ⇒ prepend one space. NSLock-guarded
   memory, updated only on didInsert. Known accepted tradeoff: a stray leading
   space in a freshly-emptied box within the window.

## Attack specifically
- Capture-file lifecycle through the arbiter paths (double-delete? leak? router
  fallback after arbiter consumed the file?).
- Re-entrancy: new dictation starting while the arbiter still transcribes.
- Guard strictness: realistic cleanups now rejected — anything egregious beyond
  the accepted policy?
- Stray-space scenarios beyond the documented one.

## Verdict format
PASS (safe to merge) or FAIL with blocking defects as file:line + concrete fix.

## Accepted tradeoffs (do NOT flag)
- Stricter guard rejects synonym-level rewrites — deliberate verbatim policy.
- Short-clip arbiter adds ~0.3–0.6s to ≤3s dictations — accepted for zero
  phantom insertions.
- Old installs keep their persisted per-app code-mode rows (this machine was
  migrated by hand; single-user app today).
- Stray leading space in freshly-emptied AX-blind boxes within 120s.
