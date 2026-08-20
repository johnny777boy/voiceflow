# Wispr Parity: What They Do, What We're Missing, and the Validated Fix Plan

Research date: 2026-08-19. Builds on `docs/RESEARCH-ACCURACY-FIX.md` (same day) and
`docs/WISPR_GAP_FINDINGS.md` (2026-08-07) — established facts from those docs are
referenced, not repeated. Every WER claim carries a citation; anything not measured
or published is explicitly marked **speculation**.

---

## (a) Executive summary — plain English

Wispr Flow is not smarter software. It sends your voice over the internet to big
computers that run a much larger listening model than the one on your Mac, and it
reads your screen to learn the names and words you use. That is their whole trick.
The price they pay is privacy: a teardown found they keep your raw audio, your
keystrokes, and your screen contents in a database and upload to their servers
hourly — even with data sharing "off". We will never copy that part.

The good news: almost every accuracy trick they use has an on-device version, and
we are missing three of them for fixable reasons, not deep ones:

1. We run the SMALLER version of Whisper. The full one hears accents about 1 point
   better. Switching is one command and a bigger download.
2. Our "tell the model your special words in advance" feature is built but switched
   off, because of a bug in a library we use — that bug was fixed upstream three
   weeks ago. We need to upgrade the library.
3. When the model mishears a word, our fixer only catches mistakes you predicted in
   advance. It should catch anything that SOUNDS like one of your words.

And one thing we already do better than Wispr: they shipped an AI cleanup that
changed users' words without asking — their #1 complaint from 700+ users. Our
CleanupGuard exists precisely to make that impossible. Keep it.

---

## (b) What Wispr Flow actually does (with citations)

### The pipeline

- **All transcription is in the cloud, none on-device.** Audio is streamed over
  gRPC to a Baseten-hosted, in-house ASR model
  (`model-v31pl413.grpc.api.baseten.co`); measured model inference ~210 ms, the
  rest network. Confirmed by both the forensic network teardown
  ([wensenwu.com investigation](https://www.wensenwu.com/thoughts/wispr-flow-investigation))
  and Baseten's own case study
  ([baseten.co/resources/customers/wispr-flow](https://www.baseten.co/resources/customers/wispr-flow/)).
- **A fine-tuned Llama does formatting/cleanup**, served via TensorRT-LLM;
  their end-to-end p99 target is 700 ms, with the Llama step required to emit 100+
  tokens in under 250 ms (Baseten case study). Transcript text is additionally
  processed by OpenAI / Anthropic / Cerebras / Fireworks for cleanup and rewriting
  (teardown).
- **Dictation models are built in-house** — their stated moat is control over
  accuracy and latency ([wisprflow.ai/research/supporting-languages](https://wisprflow.ai/research/supporting-languages)).

### The context machine (this is the accuracy edge, not the accent magic)

Per the teardown, the gRPC stream carries, alongside the audio:

- app bundle ID, foreground app name, active URL;
- the **full Accessibility tree** of the screen (observed: up to 214 elements,
  9 levels deep, ~336 ms to walk);
- the **complete contents of the active text box** (observed: a 36,191-char field);
- **proper nouns extracted by a separate LLM call** (`/llm/extract_asr_words`)
  streamed back into the transcription stream as hotwords;
- a **cloud-synced personal dictionary** that reviewers report learns a new term
  after 2–3 uses ([getvoibe.com review](https://www.getvoibe.com/resources/wispr-flow-review/)),
  plus "accent confidence scoring" — n-best comparison across candidate
  transcriptions ([wisprflow.ai languages research](https://wisprflow.ai/research/supporting-languages)).

So when Yoni says "Wispr hears me 99.99%": it is (1) a large cloud acoustic model,
(2) your own words fed to the recognizer before it decodes, (3) n-best rescoring.
No accent-specific model. This matches our 2026-08-07 findings exactly.

### What they got WRONG (do not copy)

- **"Changed words": Auto Cleanup rewrote text users hadn't asked it to touch.**
  When Wispr solicited criticism, 700+ users answered; Wispr traced accuracy
  complaints to an overly aggressive Auto Cleanup and says it corrected the
  behavior ([Digital Trends](https://www.digitaltrends.com/computing/wispr-flow-asked-its-haters-what-was-wrong-and-more-than-700-people-answered/)).
  Users also report quality "drifting" over time — a 350k-word user says it
  noticeably declined. Lesson: **an unguarded LLM pass IS the failure mode.** Our
  bidirectional CleanupGuard is the countermeasure no competitor ships
  (BACKLOG 2026-08-19, finding 4). Any accuracy work below must stay behind it.
- **The privacy bill**: 694 MB local `flow.sqlite` with raw audio BLOBs and AX-tree
  snapshots, hourly `/history/upload` even with data sharing off (metadata only),
  a system-wide keystroke CGEventTap, hardened-runtime protections disabled
  (teardown). This is the moat argument made for us — screen context can be
  harvested **on-device and discarded**, which is the version we build.

---

## (c) Gap table

"WER evidence" = published effect on accented/rare-word accuracy. "Fidelity risk" =
risk of violating "never insert/alter unspoken words".

| # | Mechanism | Do we have it? | WER evidence (accented / rare words) | On-device feasible? | Fidelity risk |
|---|---|---|---|---|---|
| 1 | Full large-v3 acoustic model (vs turbo) | **No** — turbo is default (`WhisperModelManager.swift:49`) | ~1.1 WER better on accented English, ~0.2 on clean — OpenAI's own benchmark ([whisper discussion #2363](https://github.com/openai/whisper/discussions/2363)); large-v3 lands 7–12% WER on accented English ([convertaudiototext benchmarks](https://convertaudiototext.com/blog/whisper-large-v3-explained)) | Yes — same WhisperKit path, `whisperModelVariant` override already exists; cost = bigger download, slower decode | None |
| 2 | Contextual biasing (promptTokens / hotwords) | **Built, disabled** — WhisperKit 0.18 prefill-EOT bug ([issue #372](https://github.com/argmaxinc/WhisperKit/issues/372)), fixed in [PR #514](https://github.com/argmaxinc/WhisperKit/pull/514), ships in v1.1.0 (2026-08-06) | Prompt-based biasing measurably lifts rare-word recall; trained biasing lifts B-WER by 11.6 pts / overall 0.9 ([OWSM-Biasing](https://arxiv.org/abs/2506.09448)); zero-shot fine-tuned biasing +45.6% rare-word, +60.8% unseen-word relative ([arxiv 2502.11572](https://arxiv.org/html/2502.11572v1)). Plain initial_prompt is the weakest of these — real but smaller; treat magnitude as **unquantified for our exact setup** | Yes — code exists behind `whisperPromptBiasingEnabled` | Low-medium: prompt echo/hallucination — already mitigated (`TranscriptSanity.looksLikePromptEcho`, arbiter) |
| 3 | Screen-context nouns → biasing (Wispr's `/llm/extract_asr_words`, Aqua's Deep Context) | **No** | No published WER numbers; Wispr and [Aqua Voice](https://aquavoice.com/) both ship it as their headline accuracy feature. **Speculative magnitude, plausible mechanism** (it feeds #2) | Yes — AX read + on-device FoundationModels extraction, discard after use (privacy-safe version of Wispr) | Low if output only feeds the bias prompt / dictionary candidates, never the text |
| 4 | LLM formatting pass | **Yes, guarded** | n/a | Yes (shipping) | Already handled — Wispr's version was their #1 complaint; keep guard strict |
| 5 | n-best / two-engine rescoring ("accent confidence scoring") | **No** (design deferred in WISPR_GAP round 2) | GER over n-best beats oracle-of-n-best in benchmarks ([HyPoradise](https://arxiv.org/abs/2309.15701)) but that is with big LLMs; two-engine agreement is our on-device analogue — **unquantified** | Yes — we already run two engines for the phantom arbiter | Medium: any reranker can pick a fluent-but-wrong hypothesis; must be guard-gated |
| 6 | Personal dictionary that LEARNS | **Half** — exact-match `VocabularyReplacer` + AX watcher blind in Electron (0/40 in Claude) | Wispr learns a term after 2–3 uses (reviews); no vendor publishes WER deltas — **placebo risk real**, see (e) | Yes | None if propose-only (current policy, keep) |
| 7 | Phonetic post-correction (Double Metaphone + edit distance over user vocab) | **No** — this is the VocabularyReplacer upgrade | Standard entity-resolution technique: DM skeleton + Damerau-Levenshtein ≤1 ([entity resolution for noisy ASR](https://www.researchgate.net/publication/336997171_Entity_resolution_for_noisy_ASR_transcripts); [hybrid phonetic-neural correction](https://arxiv.org/pdf/2102.06744)). Fixes exactly the `interven results`/`chat GPT` class | Yes — pure Swift, no model | Low-medium: can rewrite a real word into a vocab word; constrain hard (see plan step 4) |
| 8 | Real VAD (Silero-class) before decode | **Energy gate only** (`maxRMS<0.005 && peak<0.015`) | Effective VAD "significantly reduces WER and hallucination incidence" vs thresholds alone ([arxiv 2501.11378](https://arxiv.org/pdf/2501.11378)); note Silero v5 still passes ~40% of pure noise on ESC-50 (same paper) | Yes — Silero is tiny; WhisperKit also bundles an energy VAD | None for speech (gates only non-speech); tune against quiet-speaker false gating (the 2026-08-08 lesson) |
| 9 | Speaker-adaptive fine-tuning (personal LoRA on user audio) | **No** | Literature is strong: speaker-adaptive LoRA −24.2% relative WER (LibriSpeech-SA) ([arxiv 2408.03979](https://arxiv.org/pdf/2408.03979)); accent-expert MoE LoRA beats full fine-tuning ([MAS-LoRA](https://arxiv.org/html/2505.20006)); LoRA weights merge at zero inference cost | **No consumer product ships on-device personal LoRA today** (none found — Wispr fine-tunes centrally, VoiceInk/Superwhisper don't train). Training on-device is the unshipped part. **Long-horizon** | None at inference; training-data curation risk |
| 10 | Cloud-scale acoustic model + streaming | Deliberately no | — | No — violates the moat | — |
| 11 | Audio-side: preroll trim 0.8→0.3 s, gain normalization | Partial (deferred) | Minor; insertion-class fixes (pre-keypress speech transcribed) — WISPR_GAP audit finding 6 | Yes, but audio path = live-mic-only changes (working rule 6) | None |

Also checked and **not** worth chasing: Parakeet/Canary as a model swap — Parakeet
matches Whisper on clean English (2.6% WER) but Whisper keeps the edge on accented
speech, and Parakeet's Apple-Silicon path (MLX bindings) is slower than our CoreML
route ([whisper-vs-parakeet decision writeup](https://www.arunbaby.com/speech-tech/0073-whisper-vs-parakeet-asr-decision/),
[macparakeet.com](https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/)).
Apple SpeechAnalyzer remains unbiasable (no custom-vocab API — RESEARCH-ACCURACY-FIX Layer 1).

---

## (d) The prioritized plan, each step with its validation gate

Standing rule applied throughout: **no accuracy-affecting change merges without a
paired WER measurement on Yoni's own voice** (protocol in §d.0). Speed never buys
its way past quality.

### d.0 FIRST: make the measurement able to answer the question

The current `Scripts/wer_session.sh` reference is **136 words**. One error = 0.74
WER, so it cannot resolve a ~1-point model difference — it can only catch
catastrophes (which is what it was built for: the dead-engine class). Two upgrades,
both cheap:

1. **Same-audio paired A/B.** For model comparisons, never re-read the script per
   model. Add a benchmark mode that RETAINS the capture files (Whisper currently
   deletes on success), then decode the same files offline under both
   `whisperModelVariant`s. Identical audio removes reading variance entirely and
   makes every utterance a matched pair — the design the ASR literature scores
   with MAPSSWE / paired bootstrap ([blockwise bootstrap, arxiv 1912.09508](https://arxiv.org/abs/1912.09508);
   [Bisani & Ney bootstrap CIs](https://www.researchgate.net/publication/4087402_Bootstrap_estimates_for_confidence_intervals_in_ASR_performance_evaluation)).
2. **More words + a significance answer, not a threshold.** Extend the reference to
   ~50 utterances / ~1,000 words (read set) and add paired bootstrap (10k resamples
   over utterances) to `wer.py`, reporting "A better than B with p<0.05" instead of
   eyeballing. *Back-of-envelope (marked as our own calculation, not literature):
   detecting a 1-point absolute difference around 8% WER with independent samples
   needs ~10k words; pairing on identical audio cuts that by several-fold because
   only discordant words carry variance — ~1,000–2,000 paired words is a realistic
   floor for a 1–1.5 point effect, and the bootstrap will tell us honestly when the
   sample is too small.*

Plus two scoring extensions:

- **Entity WER (B-WER).** Score the vocabulary/proper-noun subset separately, as the
  biasing literature does (B-WER vs U-WER, [OWSM-Biasing](https://arxiv.org/abs/2506.09448)).
  Add a `docs/wer-entities.txt` list (Codex, GitHub, Claude Code, Payload CMS,
  client names, remodeling terms). Reason: biasing typically moves B-WER a lot and
  overall WER a little — overall-only scoring would wrongly call it a no-op.
- **A spontaneous set.** Read speech underestimates real-use WER, and non-native
  spontaneous speech adds disfluency effects ([non-native ASR study, arxiv 2503.06924](https://arxiv.org/pdf/2503.06924)).
  Protocol: Yoni dictates real work for a day with capture-retention on; we
  correct the transcripts afterward to create references (post-editing = the
  reference), and score read and spontaneous sets separately.

**Gate for d.0 itself:** none (measurement only), but it blocks everything below.

### d.1 Model A/B: turbo vs full large-v3 (largest single lever, zero code)

`defaults write com.voiceflow.dictation whisperModelVariant -string "openai_whisper-large-v3-v20240930"`,
re-run the paired protocol. Expected: ~1 point WER gain on his accented speech
([whisper #2363](https://github.com/openai/whisper/discussions/2363)) at real
latency cost (32-layer vs 4-layer decoder).

**Gate:** ship full large-v3 as default only if paired WER is significantly better
on his voice AND p95 dictation latency stays acceptable to Yoni living on it. If
WER ties, turbo stays and the ~1.1-point claim is falsified *for his voice* — also
a result.

### d.2 WhisperKit 0.18.0 → v1.1.0, then re-enable prompt biasing

The promptTokens/prefill-EOT bug that silenced our biasing is fixed upstream
(PR #514, ships v1.1.0, 2026-08-06 — [releases](https://github.com/argmaxinc/WhisperKit/releases)).
Migration notes gathered from the release history:

- v1.0.0 is a **major break**: deprecated APIs removed (including the
  `TextDecoderContextPrefill`/`usePrefillCache` path), the `supressTokens` typo we
  code against is renamed `suppressTokens`, MLTensor methods went async, Swift 6
  Sendable adoption; repo/product reorganized under an "ArgmaxOSS" umbrella (the
  GitHub repo now redirects to `argmax-oss-swift`) — expect `Package.swift`
  (`from: "0.9.0"`, resolved 0.18.0) to need both a version and possibly product
  changes.
- v1.1.0 adds promptTokens bugfixes and incremental audio loading.
- **Re-audit on upgrade** (existing known traps): `noSpeechThreshold` was dead
  config in 0.18 (hardcoded noSpeechProb=0) — verify whether v1.1.0 implements it
  before trusting it; the release notes do not say (unknown until we read the
  source). Same for prefill interaction issue #27 and our suppress-token list
  (PR #514 also fixed a `suppressTokens: [-1]` crash).

Then flip `whisperPromptBiasingEnabled` on and feed the vocabulary as a compact
natural sentence, highest-value terms LAST (224-token window, later tokens weigh
more — RESEARCH-ACCURACY-FIX Layer 1).

**Gate (two-stage):** (1) upgrade alone, biasing still off — paired WER must be a
tie or better vs 0.18 (upgrade must not regress); (2) biasing on vs off, same
audio — overall WER tie-or-better AND B-WER improved. Keep the prompt-echo
discard and arbiter live; count echo-discards in the session log as a tracked
failure metric.

### d.3 Phonetic vocabulary matching (kills "predict every mishearing")

Replace exact-phrase-only matching in `VocabularyReplacer` with a second, sound-
based pass: Double Metaphone key + Damerau-Levenshtein ≤1 on the phonetic skeleton,
candidates restricted to the user's vocabulary list — the standard noisy-ASR entity
resolution recipe ([ResearchGate entity resolution](https://www.researchgate.net/publication/336997171_Entity_resolution_for_noisy_ASR_transcripts),
[arxiv 2102.06744](https://arxiv.org/pdf/2102.06744)). Constraints that keep it
inside the verbatim rule:

- fires only toward words in Yoni's own vocabulary (cannot invent words);
- never fires when the transcribed word is itself a common English word with high
  unigram frequency UNLESS the phonetic match is exact (protects "period", "bridge");
- multi-word entries match by per-token phonetic keys ("clod code" → "Claude Code");
- every firing is logged with before/after for the audit script.

Fully testable offline against the known corpus (`codices→Codex`, `git hop→GitHub`,
`interven results`, `chat GPT`), independent of d.1/d.2.

**Gate:** offline replay over his real dictation history (the `VoiceFlowReplay`
harness pattern): zero false rewrites over ≥100 real dictations, plus B-WER
improvement on the entity set in the next live session. CleanupGuard stays
downstream as the seatbelt.

### d.4 Learning loop rebuild (candidates in, propose-only out)

Retire the 6-second AX watcher as the primary signal (measured blind: 0/40 in
Claude). Feed the candidate queue from signals that work everywhere:

1. explicit report (`Scripts/report_bad.py` → in-app affordance later);
2. guard refusals (the model repeatedly proposing a word the guard blocks — e.g.
   `ChatGPT` — is a self-discovered vocab candidate);
3. phonetic near-misses from d.3 (a vocab word that keeps needing correction is
   evidence the biasing prompt should carry it — promote to the END of the prompt);
4. keep AX watching only as a bonus signal where it works (Chrome: 2/2).

Wispr's "learns after 2–3 uses" is the UX bar ([reviews](https://www.getvoibe.com/resources/wispr-flow-review/));
their mechanism (cloud edit-history mining, `flow.sqlite` stores "user edit
metadata" per the teardown) is not available to us on principle, and no vendor
publishes evidence that passive edit-mining beats an explicit path — treat
passive signals as candidates only (existing policy, keep).

**Gate:** proposal precision on live use — of proposed vocab entries, Yoni accepts
≥80% (measured over 2 weeks). WER-gating is indirect here: accepted entries enter
d.2's prompt and d.3's matcher, both already gated.

### d.5 Screen-context nouns (the on-device version of Wispr's context machine)

After d.2 proves biasing works: on dictation start, read the frontmost window's AX
text (bounded, e.g. 2k chars), extract proper nouns/rare terms on-device
(FoundationModels or a simple capitalization/rarity heuristic first), append to the
bias prompt for THAT dictation only, then discard. Never persisted, never leaves
the machine — the privacy-inverted version of Wispr's `/llm/extract_asr_words`.
Note Electron/AX blindness applies here too; heuristic fallback: recent dictation
history nouns. **Magnitude speculative** (no published numbers), but it is both
Wispr's and Aqua's flagship mechanism ([Aqua Deep Context](https://aquavoice.com/)).

**Gate:** paired WER + B-WER on a benchmark that includes on-screen proper nouns;
echo-discard rate must not rise.

### d.6 Silero-class VAD gating (hallucination class, see (e))

**Gate:** zero lost-speech events on a quiet-speech test set (the 2026-08-08
false-gate lesson: thresholds were verifier-corrected once already), and fewer
phantom-arbiter invocations per 100 dictations.

### d.7 Long horizon, explicitly parked

- **Two-engine n-best rescoring** (design exists from Round 2) — only as
  guard-gated tie-breaking, never free rewriting (HyPoradise-class GER shows the
  ceiling but used server LLMs; on-device magnitude **speculation**).
- **Personal LoRA from his own corrected dictations** — literature says −12–24%
  relative WER for speaker adaptation ([arxiv 2408.03979](https://arxiv.org/pdf/2408.03979));
  nobody ships on-device training today; revisit when a benchmark set of his
  audio + verified references exists (d.0 creates exactly that corpus as a side
  effect).
- **Preroll/gain audio work** — only live with Yoni (working rule 6).

---

## (e) The extra / missing / wrong words playbook

For each failure class: what the system (not the user) does. "Have" = shipping in
this branch today.

### EXTRA words = hallucination

Whisper's signature failure: silence/low-SNR clips decode to invented fluent text;
hallucinations often carry HIGH confidence and low no-speech probability, so
logprob/no-speech filters alone provably miss them
([arxiv 2501.11378](https://arxiv.org/pdf/2501.11378), [hallucination-detection study](https://arxiv.org/pdf/2606.23060)).
Defense in depth:

| Layer | State |
|---|---|
| Energy gate before decode (maxRMS/peak) | **Have** (`WhisperKitTranscriber.swift:145`) |
| Non-speech token suppression | **Have** (0.18 shipped an empty TODO; we build the list ourselves) |
| `suppressBlank`, no VAD chunking on ≤30 s clips, temperatureFallbackCount=1 (bounded resampling) | **Have** |
| Phantom-phrase post-filter + second-engine arbiter on suspicious short clips | **Have** (this is stronger than threshold filtering, per the high-confidence-hallucination finding) |
| Real VAD (Silero-class) to trim non-speech before decode | **Missing** → d.6. Literature: effective VAD significantly cuts both hallucination incidence and WER ([arxiv 2501.11378](https://arxiv.org/pdf/2501.11378)) |
| compression-ratio rejection (repetition inflates gzip ratio > ~2.4) | **Verify at d.2**: standard Whisper recipe ([openai/whisper #679](https://github.com/openai/whisper/discussions/679)); check which of `compressionRatioThreshold`/`logProbThreshold`/`noSpeechThreshold` are actually LIVE in WhisperKit v1.1.0 (noSpeechThreshold was dead in 0.18) |
| condition_on_previous_text=False equivalent | n/a — we decode single windows, no cross-segment conditioning |
| Preroll trimming (pre-keypress speech = insertions of REAL speech, a different sub-class) | **Parked** (audio path, live-only) |

### MISSING words = truncation / early end-of-text

- **The prefill-EOT bug class** — an EOT sampled while the prompt is force-fed
  terminates the segment: that is WhisperKit #372/PR #514, i.e. exactly why our
  biasing emitted zero chars. **Fix = d.2 upgrade.** After upgrade, an
  empty-or-tiny decode on a clip with speech-level energy should be treated as a
  truncation signal → retry once without prompt (cheap, deterministic).
- **Clip-boundary losses**: first-word loss is covered by the 0.8 s preroll; the
  0.4 s min-hold discards quick real utterances (WISPR_GAP finding 6) — revisit
  with live audio only.
- **Detection**: log decode length vs clip seconds; a words-per-second floor
  (marked heuristic) flags suspicious truncations for the session audit rather
  than silently accepting them.

### WRONG words = substitution (the accent class)

Ordered by where the fix acts:

1. **Before decode — bigger model** (d.1): substitution is where the turbo decoder
   pays its ~1.1-point accent penalty ([whisper #2363](https://github.com/openai/whisper/discussions/2363)).
2. **At decode — bias the recognizer** (d.2 + d.5): the word comes out right the
   first time; biasing moves B-WER hardest ([OWSM-Biasing](https://arxiv.org/abs/2506.09448)).
3. **After decode — phonetic correction constrained to the user's vocabulary**
   (d.3): catches every mishearing that SOUNDS like a known word, needing one
   entry instead of an enumeration. Post-correction works on every engine —
   critical because 10 of 19 surveyed STT integrations silently drop dictionary
   terms at the engine level ([typewhisper survey](https://github.com/TypeWhisper/typewhisper-mac/issues/294)).
4. **Feedback — the learning loop** (d.4) turns each new substitution into a
   dictionary/bias entry with one action.
5. **Never**: free-form LLM "fixing" of words. That is Wispr's changed-words
   failure. Any future reranker chooses only among engine-produced hypotheses and
   passes CleanupGuard. (Replay already showed the guard refusing the model's
   bridge→branch repair; per BACKLOG, whether mis-transcription repair is ever
   allowed is Yoni's product call, not a default.)

---

## (f) Sources

**Wispr Flow**
- Forensic teardown (cloud gRPC, context injection, flow.sqlite, uploads): https://www.wensenwu.com/thoughts/wispr-flow-investigation
- Baseten case study (Llama formatting, 700 ms p99, TensorRT-LLM, autoscaling): https://www.baseten.co/resources/customers/wispr-flow/
- Language/accent research page ("accent confidence scoring", in-house models): https://wisprflow.ai/research/supporting-languages
- 700+ complaints, Auto Cleanup "changed words" admission: https://www.digitaltrends.com/computing/wispr-flow-asked-its-haters-what-was-wrong-and-more-than-700-people-answered/
- Personal dictionary learns in 2–3 uses; accent reviews: https://www.getvoibe.com/resources/wispr-flow-review/ · https://willowvoice.com/blog/wispr-flow-review-voice-dictation
- Transcription-quality drift help page: https://docs.wisprflow.ai/articles/6901148133-transcription-suddenly-got-worse-or-feels-less-accurate

**Models**
- turbo vs large-v3, accent penalty (~1.1 vs ~0.2 WER): https://github.com/openai/whisper/discussions/2363
- large-v3-turbo model card: https://huggingface.co/openai/whisper-large-v3-turbo
- large-v3 accented WER ranges: https://convertaudiototext.com/blog/whisper-large-v3-explained
- Parakeet vs Whisper on accents / Apple Silicon: https://www.arunbaby.com/speech-tech/0073-whisper-vs-parakeet-asr-decision/ · https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/
- Non-native English ASR (read vs spontaneous, disfluency): https://arxiv.org/pdf/2503.06924

**Biasing & correction**
- WhisperKit issue #372 / PR #514 / releases (v1.0.0 breaking changes, v1.1.0 promptTokens fixes): https://github.com/argmaxinc/WhisperKit/issues/372 · https://github.com/argmaxinc/WhisperKit/pull/514 · https://github.com/argmaxinc/WhisperKit/releases
- OWSM-Biasing (B-WER −11.6, WER −0.9): https://arxiv.org/abs/2506.09448
- Rare-word Whisper biasing, zero-shot (+45.6%/+60.8% relative): https://arxiv.org/html/2502.11572v1
- CB-Whisper (encoder KWS → decoder prompts): https://arxiv.org/html/2309.09552v3
- Phonetic post-correction: https://www.researchgate.net/publication/336997171_Entity_resolution_for_noisy_ASR_transcripts · https://arxiv.org/pdf/2102.06744 · https://arxiv.org/pdf/2102.11480
- STT engines silently dropping dictionary terms (10/19): https://github.com/TypeWhisper/typewhisper-mac/issues/294
- Apple SpeechAnalyzer lacks custom vocab: https://www.argmaxinc.com/blog/apple-and-argmax

**Hallucination**
- Non-speech-audio-induced hallucinations; VAD comparison: https://arxiv.org/pdf/2501.11378
- Calm-Whisper (−80% non-speech hallucination, <0.1 WER cost — fine-tune, not a knob): https://www.isca-archive.org/interspeech_2025/wang25b_interspeech.pdf
- High-confidence hallucinations evade threshold filters: https://arxiv.org/pdf/2606.23060
- Community mitigation recipe (compression ratio ~2.4, logprob −1.0, VAD): https://github.com/openai/whisper/discussions/679

**Rescoring / LLM correction**
- HyPoradise GER baseline: https://arxiv.org/abs/2309.15701

**Adaptation**
- Speaker-adaptive LoRA (−24.2% rel WER): https://arxiv.org/pdf/2408.03979
- MAS-LoRA accent-expert mixture: https://arxiv.org/html/2505.20006

**Measurement**
- Blockwise/paired bootstrap for WER significance: https://arxiv.org/abs/1912.09508 · https://www.researchgate.net/publication/4087402_Bootstrap_estimates_for_confidence_intervals_in_ASR_performance_evaluation · https://github.com/ogunlao/asr_stat_significance

**Competitors (learning loops)**
- Aqua Voice Deep Context / phonetic layer: https://aquavoice.com/ · https://productivity.academy/news/speech-text-aqua/
- VoiceInk / Superwhisper dictionaries: https://dictor.io/blog/voiceink-vs-superwhisper · https://www.getvoibe.com/resources/superwhisper-vs-voiceink/
