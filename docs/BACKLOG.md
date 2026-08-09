# VoiceFlow — Backlog & Handoff (resume point)

Last updated: 2026-08-08 (late session). Read CLAUDE.md first (workflow ritual +
product principles), then this, then docs/ROADMAP.md (phased plan to sellable).

## 🔤 Vocabulary is EMPTY — the single highest-value thing Yoni can do

`defaults read com.voiceflow.dictation vocabulary` returns nothing: there are no
entries at all, while `useWhisperEngine = 1` (large-v3 turbo, downloaded). So
Phase 1's biasing is running with none of HIS words to bias toward — it only has
screen-harvested nouns. This is why "Codex" comes out as "codices" (a real English
word, so the recognizer never self-corrects) and why other proper nouns keep
failing. One entry — spoken `codices` → written `Codex` — both feeds `Codex` to
Whisper as a prompt token AND rewrites the miss. Phase 4 now offers such entries
automatically after three hand-corrections (capitalized ⇒ passes the name-shaped
gate). Ask him for his list of mangled terms and write them in.

## ✅ AUTONOMOUS RUN COMPLETE — Codex FAILed twice (both fixed), awaiting round 3

Phases 1–5 built, reviewed, fixed, and INSTALLED. `feature/upgrades-phase1-5`.
173 tests, 0 warnings (debug + release). App rebuilt from the branch and installed
to `/Applications/VoiceFlow.app` (relaunched, running).

**Codex round 3 (`511221d`) returned FAIL — the `>= 0.5` threshold passed PARTIAL
echoes:** user says three of their terms, the decoder completes the glossary with
the other two, the arbiter hears the three real ones → 3/5 = 0.6 cleared it and
"Payload CMS" was inserted. **Fixed by deleting the scoring entirely:** Whisper's
text now stands only if EVERY word in it appears in the arbiter's transcript
(`TranscriptSanity.isFullyCorroborated`), else the arbiter's transcript wins. No
threshold left to tune. **Lesson worth keeping:** three consecutive FAILs were all
similarity scores, and partial agreement is exactly the shape of a partial echo —
when the requirement is absolute ("never deliver an uncorroborated word"), encode
it exactly instead of approximating it.

**Codex round 2 (`c48db01`) returned FAIL — confirmed the capture fix, then found
the agreement check I added to make echo false-positives harmless was itself
broken:** `wordOverlap` divided by the SHORTER transcript, so a subset scored a
perfect 1.0. User says only "Sarah", Whisper echoes "Sarah Kubernetes Payload CMS
Grafana", the arbiter correctly hears "Sarah" → declared agreement → the whole
echo delivered. **Fixed:** divide by `max(a.count, b.count)`, so both transcripts
must be covered; two regression tests pin it. Consequence accepted on purpose:
genuine disagreement now prefers the arbiter and can drop a word the other engine
heard — inserting unspoken words is unacceptable, losing one is not.

**Codex round 1 (`fab60de`) returned FAIL — one blocking defect, correctly found:**
prompt-echo recovery could lose real speech. The Apple arbiter took the recorder's
shared capture URL and deleted it in a `defer` that runs even when it throws
afterwards (failed model install), so an `.unavailable` verdict left the fallback
engine nothing to read. The echo path I added throws on `.unavailable` (unlike the
pre-existing phantom path, which falls through), so the echo fix introduced it.
**Fixed:** the arbiter now works on a private COPY of the `.caf`, and
`SpeechAnalyzerDictation` consumes the capture it was handed rather than the
recorder's shared slot. Codex's second point (vocabulary-dense speech tripping the
echo test) is handled by comparing the two transcripts — agreement ≥ 0.5 keeps
Whisper's text — rather than by weakening detection.

**Yoni's next actions, in order:**
1. **Live-test the installed build** — it is the branch, not main. Rollback if
   anything is wrong: `git checkout main && bash Scripts/build_app.sh release &&
   ditto dist/VoiceFlow.app /Applications/VoiceFlow.app`.
2. **Paste `docs/CODEX-BRIEF-UPGRADES.md` into Codex** and bring back the verdict.
3. On PASS: merge ritual per CLAUDE.md §5 (tag `pre-upgrades-merge-2026-08-08`,
   `git merge --no-ff`, tests on the merge, tag `verified-2026-08-08-upgrades`,
   push with tags, rebuild+reinstall from main).
4. **Then: the microphone idle-timeout branch** (see "Decided, not yet built").

**Two reviewer agents ran on the full diff.** Both Criticals and all nine
Importants were fixed in `539465b` (read that commit message — it is the record
of where this code was actually dangerous). Headlines: Whisper could read its own
bias glossary back as the transcript; Phase 5 voting was scoped to screen terms
instead of the user's vocabulary; the AX screen read had no working timeout; and
two-phase delivery held the dictation lock across the second LLM pass, which
silently truncated the NEXT utterance.

**Deferred, non-blocking** (both reviewers, Minor/Nit): `prewarm()` warms with
hardcoded instructions that may not match the resolved mode; `setEditedAfterInsert`
is a non-atomic read-modify-write that could resurrect a just-trimmed record;
`SuggestedVocabularyStore.persist()` does small synchronous disk I/O on the main
actor; `DictationStats` counts a <6s-old record as unedited before its correction
window closes; the voting path normalizes whitespace when it substitutes;
`AppCoordinator.cancel()` is unreachable dead code.

## 🎤 Decided, not yet built — microphone idle-timeout (Yoni asked 2026-08-08)

Yoni noticed the macOS mic indicator is on all day and asked why, since Wispr's
only appears on press. Answer: the `AVAudioEngine` is kept warm permanently with a
tap filling an ~0.8s pre-roll ring, so the audio from BEFORE the keypress is
prepended and the first word isn't clipped — his own design decision, and it works.
Measured cost on his machine: **0.1% CPU lifetime / 0.3% instantaneous, 123 MB,
no power assertion** — so the objection is the indicator light and a little
battery, NOT CPU load.

Plan (own branch, HIS choice was "finish the current run first"): shut the engine
down after N minutes idle, restart on key-down; stay warm during an active
session. Risk is exactly the bug the warm mic exists to prevent — the first
dictation after idle may clip. **Audio-capture path ⇒ CLAUDE.md rule 6: only with
Yoni present, verified live + by WER.** Do not build it while he is asleep.

## 🤖 AUTONOMOUS RUN — approved by Yoni 2026-08-08 (executed; kept for the record)

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
