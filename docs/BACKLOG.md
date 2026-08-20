# VoiceFlow — Backlog & Handoff (resume point)

## ▶️ RESUME HERE (2026-08-19)


**2026-08-19 LATE — the parity plan is BUILT (branch `feature/accuracy-parity`,
installed `0af7359`, 213 tests, 0 warnings). Everything that did not need his
voice is done; the two things that do are now two commands.**

What landed:
- **WhisperKit 0.18.0 → 1.1.0.** Cost exactly one line (`supressTokens` typo
  renamed). Verified by decoding real audio, not assumed.
- **Context biasing WORKS.** PR #514 fixed the prefill-EOT bug. Proven live:
  "the payload CMS" → "the Payload CMS", "Whisperflow parody" → "Whisper Flow
  Parity". Still ships OFF pending WER on his voice.
- **The prompt had to become a sentence.** A bare list of Capitalised Terms made
  Whisper copy the LIST'S STYLE into the transcript ("Work Needs Aware Benchmark
  on My Voice"). `promptText` now emits prose, terms last, with a plain-prose
  closing clause. Measured before/after.
- **`VoiceFlowBench`** decodes any audio through the PRODUCTION path (Whisper
  moved into a `VoiceFlowWhisper` library so the harness cannot drift from the
  app). `wer_compare.py` scores two runs paired per utterance with a bootstrap
  CI/p-value, plus entity recall, plus number normalisation (that alone was
  costing 6.9 WER of pure formatting noise).
- **`Scripts/bench_session.sh`** — `start` → `prompts` → `models` / `bias`.
  Capture retention turns one dictation session into a corpus that can be
  re-decoded under any configuration, so nothing is ever measured by re-reading.
- **Phonetic near-miss detection** replaces the blind AX watcher as the learning
  signal. DETECTS ONLY — "codecs"/"codices" are real words, so substitution
  would destroy words he meant.

**HIS TWO COMMANDS (nothing else is blocked on anything else):**
```
Scripts/bench_session.sh start     # then quit + reopen VoiceFlow
Scripts/bench_session.sh prompts   # read 50 lines, one dictation each
Scripts/bench_session.sh models    # turbo vs full large-v3 on HIS voice
Scripts/bench_session.sh bias      # biasing off vs on, same audio
```
Both models are already downloaded, so neither costs a wait.

**Gates before anything ships as default:** full large-v3 becomes default only
if paired WER is significantly better AND he accepts the latency (measured
+31% decode on synthetic: 0.61s → 0.80s). Biasing turns on only if entity
recall rises without overall WER regressing.

**KNOWN:** WhisperKit 1.1.0 vendors an unused TTSKit module that fails Swift 6
strict concurrency, so a BARE `swift build` shows errors unrelated to this app.
Use `--product VoiceFlow` / `--product VoiceFlowTests` (build_app.sh already does).


**2026-08-19 EVENING — the full parity plan is in
`docs/RESEARCH-WISPR-PARITY-PLAN.md` (agent-researched, cited).** Wispr = cloud
scale + context injection + a privacy bill we refuse; our gaps are the turbo
model, dead biasing (upstream-fixed, needs v1.1.0 — BREAKING upgrade), and
exact-match vocab. Their #1 shipped failure is the thing CleanupGuard prevents.
NOTE: the 136-word WER script cannot resolve the model question (one error =
0.74 WER) — plan step d.0 upgrades measurement FIRST (retain capture audio,
same-audio A/B, ~1,000 words, paired bootstrap, entity-WER). Do d.0 before
trusting ANY accuracy number beyond catastrophe detection.

**2026-08-19 RESEARCH — read `docs/RESEARCH-ACCURACY-FIX.md` first.** He said
Whisper hears him 99% correctly and we do not. We run Whisper too — but the
**turbo** build (decoder truncated 32→4 layers). OpenAI's benchmarks: full
large-v3 is ~0.2 WER better on clean English and **~1.1 WER better on accented
English**. He is a non-native speaker, so we picked the model whose distillation
costs him the most, and never WER-gated it. The A/B needs no code:
`defaults write com.voiceflow.dictation whisperModelVariant -string
"openai_whisper-large-v3"`. (The old source comment named
`openai_whisper-large-v3_turbo` as "full large-v3" — FALSE, every `*_turbo`
folder is turbo; that A/B would have compared turbo with turbo. Corrected.)
Also: the promptTokens bug that disabled biasing is upstream issue #372, FIXED
in PR #514, shipping in WhisperKit v1.1.0 — we are pinned at 0.18.0.

> **CORRECTED 2026-08-19 (third instance of this trap).**
> `openai_whisper-large-v3-v20240930` reports `decoder_layers: 4` — it is TURBO;
> `v20240930` is the turbo release date. The real full model is
> **`openai_whisper-large-v3`** (`decoder_layers: 32`), verified against the
> published config. File size cannot tell them apart (both decoders are 328 MB),
> so `VoiceFlowBench` now reads `decoder_layers` from the model's own config and
> prints it, and `bench_session.sh` refuses to score byte-identical outputs.



**PROOF IN ONE COMMAND (2026-08-19):** `swift run VoiceFlowReplay --prove`
runs 12 dangerous edits through the REAL guard and prints plain-English
verdicts — 9 that must be blocked (severed clause, deleted word, invented word,
flipped negation, changed number, reversed debt, swapped preposition,
might→will) and 3 that must still be allowed. Against the pre-`424ef4a` guard it
reports **2 FAILED**; against HEAD, all 12 correct. This is the answer to "how
do we know it is working" for the SAFETY half — the accuracy half still needs
`Scripts/wer_session.sh`.
**Yoni says on return:** *"Continue VoiceFlow — read the RESUME HERE section."*

**State:** branch `feature/latency-instrumentation` (folder `VoiceFlow-accuracy`),
head `8c83bd2`, 207 tests, 0 warnings, installed and running. `main` (folder
`VoiceFlow Main`) is 8 days stale and still has the DEAD Whisper engine — do not
offer it as a rollback. Rollback = `Scripts/rollback_app.sh`.

**His job, 3 minutes, the only thing that settles the accuracy argument:**
```
cd ~/Documents/projects/VoiceFlow/VoiceFlow-accuracy
Scripts/wer_session.sh prompts     # read the 10 lines aloud, one dictation each
Scripts/wer_session.sh score       # get a real number
```
Whisper large-v3 benchmarks ~7-8% WER; Apple's engine ~14%. If he lands near
7-8%, transcription is fine and every remaining complaint is cleanup/formatting.

### What tonight actually established (all measured, not reasoned)

1. **Whisper was silently dead for 8+ days.** Toggle on, model on disk, every
   dictation served by the weaker Apple engine, no error anywhere. Two causes:
   tokenizer resolving into TCC-protected ~/Documents, and promptTokens making
   WhisperKit 0.18 emit zero characters. Biasing disabled behind
   `whisperPromptBiasingEnabled`; ROOT CAUSE STILL OPEN.
2. **His accuracy complaint was never transcription.** Whisper hears him
   correctly. The failures were all in cleanup.
3. **The model was REFUSING his dictations.** Handed a bare transcript, Apple's
   model reads second-person speech as a message addressed to it: "I'm sorry, but
   I cannot help you with that", 3/3 runs. Another dictation made it write a
   whole change-order letter. Fixed by delimiting the transcript with the framing
   the whole category converged on (Voicebox/Handy/VoiceInk/Whispering).
   MEASURED before/after on his Mac — see commit `9d4fc5b`.
4. **His guard is genuinely ahead of the market.** No shipped competitor verifies
   the AI didn't change your words; Wispr shipped that failure publicly (700+
   complaints, "changed words users hadn't asked it to touch").
5. **Keep the guard strict at the WORD level.** "Cultural Ghosting" (CHI EA '26):
   semantic-similarity guards pass the edits that erase a non-native speaker's
   voice — 10.26% identity-erasure at 0.748 semantic similarity.

### OPEN — highest value first

### 2026-08-19 — "how do we know for a fact?" — three things now measured

He asked the right question: unit tests cannot answer it, because the same
person wrote the tests and the code. So `swift run VoiceFlowReplay` now drives
the PRODUCTION cleanup path over dictations he actually spoke (the provider had
to move from the app target into Core first — nothing but the app could run it).
Cross-validated against the app's own live audit; both agree.

1. **The guard is NOT the problem.** 0 rejections, live (6/6 accepted) and in
   replay (8/8, 5/5). I predicted the opposite. Two independent paths agree.
2. **The model is a light punctuation pass.** Capitalises, adds a comma or final
   period, drops "uh" — and leaves 77-word run-ons. THE PROMPT IS WHY: at
   `standard` it says "do NOT merge sentences" and "keep their sentence
   structure", and never asks for sentence breaks.
3. **`cleanupStrength` is inert.** standard vs aggressive over five real
   run-ons: byte-identical output, 45→51 sentences, 86→77 longest, both times.

**Refuted, do not re-litigate:** the guard is not eating the polish; the model
does not degrade on long input (splitting a 76-word run-on cleaned no better and
produced a wrong break, "we need to actually like. Go to the backlog").

**The prompt was NOT the lever — measured, three variants, 25 real dictations:**

| prompt | sentences | longest sentence |
|---|---|---|
| original (never asks for segmentation) | 106 → 118 | 86 → 77 |
| long explicit "break run-ons, never sever a clause" | 106 → 112 | 86 → **86 (worse)** |
| short "break it into sentences, move no word" | 106 → 118 | 86 → 77 (identical) |

More instruction made the small model do LESS. The short version was a no-op.
Both were reverted rather than shipped as churn. **Do not re-try prompt wording
for run-ons without new evidence** — the on-device model will not segment his
speech however it is asked. If run-ons are to be fixed, the next candidate is
DETERMINISTIC segmentation in `RuleBasedCleanup` (now much safer to attempt,
because `severedClause` catches the dangerous breaks), and it needs its own
brainstorm before any code.

**Landed instead (`424ef4a`): the guard's punctuation blind spot is closed.**
It checked words and only words, so a split — which changes no words at all —
was invisible. Probed before touching anything, and ACCEPTED all three of:
"call me before the meeting we can decide then" → "Call me. Before the
meeting…"; "I will not send it until you confirm" → "I will not send it.
Until…"; "we need to actually like go to the backlog" → "…actually like. Go
to…". The first two change what he said. Verified over 25 real dictations to
fire ZERO times — a seatbelt for future segmentation work, not a new
restriction on today's output.

**Also seen in the replay, worth a decision:** the guard refuses the model's
attempt to fix "bridge" → "branch" (a real Whisper mis-hearing) because that is
a dropped word, and refuses it removing his profanity. Both are the strict
policy working as designed; whether mis-transcription repair should be allowed
is Yoni's call, not a bug.

1. **THE AUDIT IS LIVE — use it.** Dictate normally for a few hours on the
   installed build, then:
   ```
   Scripts/audit_cleanup.py            # summary
   Scripts/audit_cleanup.py --rejected # only what the guard threw away
   ```
   It shows what the AI PROPOSED, whether the guard kept it, and WHY it refused.
   Until this ran there was no way to answer "it's not accurate" — see below.
2. **Codex verification + merge.** 24 commits unmerged. Until this lands, `main`
   stays broken and rollback is compromised. Round 1 PASSED capture ownership,
   round 2 FAILED on pronoun reordering (fixed, `a8cbd06`). Needs a re-run at
   `bea6ce1`. The brief is REFRESHED and ready to paste:
   `docs/CODEX-BRIEF-RECOVERY.md` (round 3 — new guard rule, audit ordering,
   and an instruction to attack the guard adversarially).
3. **WhisperKit promptTokens root cause** — Phase 1's headline feature is dormant.
4. **The WER number** — never measured, needs his voice.
5. **Latency**: measured bill is ~0.65s decode + ~1.2s cleanup. Two-phase delivery
   is built and OFF; live-testing it is the cheapest felt-latency win.
6. **Learning dictionary**: 0 suggestions in 224 dictations — design mismatch.

### Do NOT do (learned the hard way tonight)
- Do not add a discourse-marker word LIST (like/well/okay/right/actually). Audited
  14/14 meaning losses. Position-gated rules only.
- Do not relax the guard to semantic similarity (see #5 above).
- Do not add "er" or "mm" to fillers ("the ER doctor", "50 mm trim").
- Do not touch the audio-capture path without Yoni present (CLAUDE.md rule 6).

### 2026-08-19 — what his 28 dictations actually say (measured, not argued)

He said "it still not accurate". The history database answers most of it:

- **The engine is healthy.** Whisper served 27 of 28, zero errors, and the raw
  transcripts read accurately. The one Apple-engine dictation is the worst text
  in the set — evidence for the engine, not against it.
- **Cleanup is nearly a no-op.** 21 of 28 delivered text BYTE-IDENTICAL to the
  raw transcript. Where it fired it capitalised a first letter, applied
  vocabulary ("codex"→"Codex"), and once made a real repair ("Why it can be" →
  "Why can it be").
- **What his text actually reads like:** 6.4% of delivered words are discourse
  markers (like×28, so×20, actually×9, "I mean"×8), longest sentence 73 words,
  5 sentences over 40 words. He edited after insert only 2/28 (7%).
- **So the complaint is presentation, not transcription** — which the 2026-08-18
  session suspected and could not prove. WER is still the missing number.

**The blind spot, now closed (`bea6ce1`).** "cleanText == rawText" was
indistinguishable between "the model had nothing to fix" and "the model fixed it
and the guard reverted every word". History now records `cleanupProposed`,
`cleanupDecision` and `cleanupRejectReason`, and `Scripts/audit_cleanup.py`
reports them (engine split, decision breakdown, ranked refusal reasons, and how
the delivered text reads). `CleanupGuard.rejection()` is the single source of
truth — `preservesMeaning` is defined as "no reason" — so the audit can never
disagree with the verdict the guard actually took.

**Two Settings lies found while looking:** "Use AI cleanup (requires API key)"
reads OFF but is ignored entirely on macOS 26 (on-device cleanup always runs);
"Redact private transcripts" is wired to NOTHING. The second is spawned as its
own task and matters more now that a third copy of each dictation is stored.

### FIXED 2026-08-19 — `sharesStem`: a prefix is not a stem (`08b14c5`)

The hole, under BOTH policies: any word of ≤4 chars that prefixed a longer word
forgave DELETING or INVENTING that longer word. "we need to dig a new well" →
"we need to dig a new" was ACCEPTED. The partners were the words in every
sentence he speaks — and several of them prefix his own vocabulary:
we/well, we/went, it/item, in/into, **at/attic, be/beam, do/door**, us/used,
the/there, an/and.

Now a short stem must GROW BY AN INFLECTION (`s/es/ed/ing/er/est/ly`, plus
`d/r/st` on an "e" stem, plus final-consonant doubling so stop→stopped), and a
1-2 letter stem is never a stem — verb forms that short are irregular, and
`sameIrregularVerb` already covers them.

Two EXISTING tests were the safety net for what the strictness cost:
"do not touch it" → "Don't touch it." had been passing only because "do"
prefixed the contraction head "don". That now has its own precise rule — an
"n't" head is forgiven only when its base word was actually spoken — and
stop→stopped needed the doubling case. Neither would have surfaced without
running the suite.

Residual, measured against `/usr/share/dict/words`: a thin "-er" tail
(corn/corner, off/offer, cent/center) survives. It needs BOTH words in the same
dictation, unlike the old hole which fired on "we". Left alone deliberately —
tightening further rejects real repairs (own→owner, low→lower).

Expected felt effect: the guard now REJECTS a few edits it used to allow, so
slightly more output arrives rule-based/verbatim. That is the correct direction
(verbatim fidelity outranks polish), but it is a behaviour change worth watching
for in daily use.


Last updated: 2026-08-10. Read CLAUDE.md first (workflow ritual + product
principles), then this, then docs/ROADMAP.md (phased plan to sellable).

## ✅ MERGED 2026-08-10 — mic idle-release (merge `ac5c0dc`)

Full ritual: Yoni live PASS + both reviewer agents clean (6 minors hardened) +
Codex PASS first try. Tags: `verified-2026-08-10-mic-idle` (current) ·
`pre-mic-idle-merge-2026-08-10` (rollback). 178 tests. App rebuilt from main and
installed. Both feature branches deleted; main is the only branch.

## 🚨 2026-08-18 SESSION — the silent-engine defect, found and fixed (branch, unmerged)

The instrumentation branch's first week of data exposed the worst kind of bug:
**High Accuracy was on, the model was on disk, and every dictation for 8+ days
ran on the Apple engine.** No error anywhere. Root cause chain, proven by live
A/B with Yoni dictating:

1. (Latent, fixed) The LOAD-time WhisperKitConfig omitted downloadBase/
   tokenizerFolder, so the tokenizer resolved to TCC-protected ~/Documents.
   Files copied into App Support; config now pins both.
2. (The killer, HOTFIXED) Feeding promptTokens makes WhisperKit 0.18 decode
   EVERY clip to zero characters → emptyTranscript → silent Apple fallback.
   Prompt off ⇒ Whisper transcribes normally (0.5-0.6s decode!). Biasing is
   DISABLED behind dev switch `whisperPromptBiasingEnabled` (ships false); the
   echo defense is gated on a prompt actually being fed. ROOT CAUSE INSIDE
   WHISPERKIT STILL OPEN — re-enable only with the fix + WER proof.
3. (Prevention, built) 180s load watchdog (stuck .preparing → visible .failed
   with Retry; generation-bumped so zombie completions are discarded) +
   EngineHealthBanner in the MAIN window whenever enabled && !ready.

Also this session: full audit (insertion 213/213 clean, 96% unedited, usage had
collapsed during the silent-degradation week — it tracks accuracy trust);
per-stage data shows the real bill is decode ~0.65s + LLM cleanup ~1.2s
(cleanup is now the latency target, arbiter ≈ 0); emptied-field fix (sending
before the 6s window is neither an edit nor a correction).

**Ritual in progress on this branch:** reviewers running → fix findings →
CODEX-BRIEF → Yoni's PASS → merge. Then: cleanup-latency package (two-phase
live test) → biasing root-cause + WER harness → learning-dictionary redesign
(0 suggestions in 224 dictations — the 6s window doesn't match his behavior).

## ⚖️ STANDING RULE (Yoni, 2026-08-10): speed may NEVER cost quality

Explicit instruction: "we don't want to lose or compromise the current quality
under no circumstances." Every latency change is therefore gated on proof of
accuracy parity, not vibes:
- No model downgrade, trigger-narrowing, or pipeline cut merges without a WER
  A/B on Yoni's voice (Scripts/wer.py, docs/ACCURACY_BENCHMARK.md protocol)
  showing no regression, plus the zero-edit rate holding in daily use.
- The safety machinery (phantom arbiter, unconditional echo defense, strict
  CleanupGuard, verbatim rules) is not a latency budget. Cuts come from waste
  (redundant work, over-broad triggers, dead time), never from checks.
- If a speed option's accuracy cost is unknown, it ships OFF by default behind a
  setting until measured — like two-phase delivery today.

## ⏱️ NEXT UP — latency instrumentation (the standing complaint)

Yoni's verdict on the whole run: accuracy/trust good, "it's not that fast" —
correct. Median release→insert is ~2.1s vs the 1.5s target, and time does NOT
track utterance length, so a variable per-dictation cost (prime suspect: the
second-engine arbiter runs) dominates. Phase 2 only measured END-TO-END.

Next session, in order:
1. New branch: per-stage timing (whisper decode / arbiter / cleanup / insert)
   recorded per dictation into TranscriptRecord (additive SQLite migration, same
   pattern as insertLatencySeconds). NOT the audio path — safe to build solo.
2. Yoni dictates normally for a day; read the distribution from history.
3. Attack the top cost with data (likely: tighten when voting/echo trigger the
   arbiter — Codex ruling says tighten the TEXT heuristic, never doubt-gates).
4. Offer the two-phase delivery live test (Settings toggle exists, off).

## 🔤 Vocabulary covers the RIGHT spellings, not the WRONG ones

CORRECTION (an earlier note in this file claimed the vocabulary was empty — that
read `defaults read com.voiceflow.dictation`, the wrong store). Settings live in
`~/Library/Application Support/VoiceFlow/settings.json`, and there are **12
entries**: `payload cms`→`Payload CMS`, `next js`→`Next.js`, `postgres`→
`PostgreSQL`, `codex`→`Codex`, `type script`→`TypeScript`, etc.

The real gap: every entry maps a CORRECTLY-heard spoken form to its written form.
`VocabularyReplacer` only fires on a whole-word match of `spoken`, so when the
recognizer produces "codices" the `codex`→`Codex` row never matches. The written
forms DO feed Whisper's prompt bias (that part works), but the replacer — the
safety net for when biasing loses — is covering the cases that don't need saving.

Fix: add rows for the actual MISHEARINGS (`codices`→`Codex`, and whatever else he
reports). Phase 4 now proposes exactly these automatically after three hand
corrections, since a capitalized target passes the name-shaped gate.

## ✅ MERGED 2026-08-09 — Codex PASS on round 7 (`7c8235b`), Phases 1–5 on main

Merge `ed0d2b5`; tags `verified-2026-08-09-upgrades` (current) ·
`pre-upgrades-merge-2026-08-09` (rollback). 178 tests on the merge, pushed with
tags. Seven Codex rounds total: six FAILs (all real, all in prompt-echo
recovery), then PASS with probes confirming .NET/#Swift/+Type/.38/push-to-talk
tokenization and the capture lifecycle.

## 🎤 LIVE TEST PASSED (Yoni, 2026-08-09): light off at ~3 min; engine restarted
on his next dictation (audio-in assertion observed 19s old); first word intact.
Reviewer agents running on the mic diff → then Codex brief → then merge.

## Mic idle-release details (`feature/mic-idle-timeout`, installed)

The installed app = main + the idle-release fix (branch pushed, 178 tests, 0
warnings). Engine releases the mic 3 minutes after the last dictation → orange
indicator goes DARK; hotkey press restarts it. Settings ▸ General toggle
"Release the microphone when idle" (on). Yoni's live test: (1) wait ~3 idle
minutes → light off; (2) first dictation after idle — press, wait a beat, speak —
check the first word; (3) rapid back-to-back dictations — should feel exactly as
before. After his verdict: reviewer agents + Codex brief for THIS small branch,
then merge per ritual.

## Previous run (kept for the record) — Codex FAILed twice, then twice more, then PASS

Phases 1–5 built, reviewed, fixed, and INSTALLED. `feature/upgrades-phase1-5`.
173 tests, 0 warnings (debug + release). App rebuilt from the branch and installed
to `/Applications/VoiceFlow.app` (relaunched, running).

**SETTLED (Codex ruling, round 6, adopted 2026-08-09): the prompt-echo defense is
UNCONDITIONAL.** No confidence gate, no energy gate — prompt continuation can be
confident, and audible audio does not prove the emitted terms came from speech.
The accepted price: vocabulary-dense sentences ("Payload CMS and Next.js") can
trigger an extra ~1–2s Apple arbiter run, and when the engines disagree the
arbiter's text wins (lose a word, never insert one). If live use shows the cost
is too high, tighten `looksLikePromptEcho`'s text heuristic or the corroboration
policy — do NOT reach for doubt signals. Do not relitigate without Codex.

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
