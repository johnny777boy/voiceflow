# VoiceFlow — Backlog & Handoff (resume point)

Last updated: 2026-08-08 (late session). Read CLAUDE.md first (workflow ritual +
product principles), then this, then docs/ROADMAP.md (phased plan to sellable).

## 🤖 AUTONOMOUS RUN — approved by Yoni 2026-08-08 (execute on resume)

Yoni's instruction: build the remaining upgrade phases AUTONOMOUSLY, verify with
both reviewer agents, prepare the Codex brief + paste message, and STOP before
merging — he tests the installed build and pastes the Codex verdict when back.

**Scope (in order), all on ONE branch `feature/upgrades-phase1-5` off main:**
1. **Phase 1 — Context biasing**: (a) verify the pinned WhisperKit contains the
   promptTokens fix (argmax PR#514) — bump the package if not, re-audit the
   noSpeechThreshold/suppressTokens notes on any bump; (b) enabled vocabulary →
   Whisper promptTokens (tokenizer-encoded, < specialTokenBegin, cap length);
   (c) AX screen-noun harvesting: frontmost window text via Accessibility →
   extract proper nouns/unknown tokens on-device → add to the per-dictation
   prompt (cap total prompt; log what was fed for debugging). NEVER screenshots.
2. **Phase 2 code parts — measurement/visibility**: rawText shown next to
   cleanText in the history UI; release-to-insert latency metric recorded per
   dictation (hold time excluded); simple zero-edit counter if cheap. (The WER
   recording session itself needs Yoni's voice — leave instructions, don't fake.)
3. **Phase 3 — latency (safe parts only)**: warm/reuse the LLM session from
   record-start; tier/skip LLM cleanup for short utterances (<~8 words) in
   casual modes; move the 0.18s drain off the main thread WITHOUT touching tap/
   preroll/format logic; reuse analyzer instances if safe. Two-phase delivery
   (insert-then-refine) ONLY behind an off-by-default setting, flagged for live
   testing. DO NOT touch the audio-capture path (CLAUDE.md rule 6).
4. **Phase 4 — learning dictionary (propose, don't silently mutate)**: detect
   post-insertion corrections via AX where readable (short window, on-device);
   when the same correction recurs 2-3×, ADD to a "suggested vocabulary" list
   surfaced in Settings ▸ Vocabulary for one-click accept. No silent auto-add.
5. **Phase 5 — word-level dual-engine voting (conservative)**: when Whisper's
   segment avgLogprob is low OR output contains near-miss of vocabulary terms,
   run the Apple engine on the same clip; where the engines disagree on a word,
   prefer the vocabulary-consistent/higher-confidence one. NEVER introduce a
   word neither engine produced. Keep per-dictation cost bounded (skip when
   confident). Extends the existing silence-arbiter plumbing.

**Standing constraints:** keep CleanupGuard STRICT (F4 decision is Yoni's, not
ours); English-only (languageCode plumbing untouched); every step unit-tested
where testable; 0 warnings; commit per phase with clear messages; push the
branch; build + install the final app (backup current /Applications copy
first); update this backlog + status.json. Then: both reviewer agents on the
full branch diff, fix all Critical/Important, write docs/CODEX-BRIEF-UPGRADES.md
+ a short paste message for Yoni, and STOP (no merge without his Codex PASS).

**Yoni's reminder message after /clear** (also give it to him):
"Continue VoiceFlow. Read docs/BACKLOG.md and execute the AUTONOMOUS RUN
section per CLAUDE.md. Build everything, verify with both reviewer agents, fix
findings, install the build for me, and give me the Codex paste message. Don't
merge until I paste the Codex PASS."

## ✅ Phase 0 MERGED (2026-08-08) — resume with Phase 1
`fix/consistent-chat-formatting` merged to main (merge `3a41efe`) after the full
ritual: both reviewer agents + Codex (initial FAIL on the 1-char guard exemption
→ fixed in e85a45e, contraction-shards-only → Codex PASS). Tags:
`verified-2026-08-08-formatting` (current) · `pre-formatting-merge-2026-08-08`
(rollback). 109 tests, 0 warnings. App rebuilt from main and installed.
**Next: Phase 1 (context biasing) from docs/ROADMAP.md on a fresh branch** —
step 1 is verifying the pinned WhisperKit contains the promptTokens fix (PR#514).

**Decisions queued for Yoni (do not act without him):**
1. Guard strictness (adversarial F4): the bidirectional guard rejects most
   grammar-level cleanups (number-words→digits, gonna→going to, irregular verbs
   go→went), so LLM cleanup ≈ punctuation pass. Options: keep strict (current,
   verbatim-first) / add narrow equivalences (numbers, irregular verbs — but NOT
   function-word insertions, that's how 'Thank'→'Thank you.' happened) / a
   "grammar help" cleanup level. His accent makes this a real tradeoff.
2. Multi-language: market research says table stakes; his policy is English-now,
   Hebrew-secondary-later. Roadmap documents the tension.
3. Watch item (adversarial F3): short dictations pay Whisper+Apple serially
   (~1-2s extra). If "yes"-type replies feel slow, Phase 3 latency work rises.

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
