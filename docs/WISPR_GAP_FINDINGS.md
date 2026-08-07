# Where the Wispr Flow gap actually is — research findings (2026-08-07)

Four-agent deep dive: Wispr's real stack (forensic teardown + their own posts),
Whisper/WhisperKit accent tuning, Apple-engine accent levers, and a very-thorough
audit of our own pipeline. Full agent reports are summarized here; this is the
canonical answer to "why is Wispr more accurate on my voice, and how do we match it."

## The headline

**Wispr is not a better-tuned on-device app — it's a cloud service.** A forensic
network teardown + Baseten's official case study confirm: audio is OPUS-streamed
to a self-hosted large ASR on dedicated GPUs *while you speak* (zero on-device
transcription at any tier), with per-language engine ensembles, and a fine-tuned
Llama cleanup pass trained on real user edits. Their accent edge = (a) a much
bigger acoustic model than Apple's, (b) heavy contextual biasing — they read your
screen via Accessibility, LLM-extract proper nouns, and feed them as ASR hotwords
plus a cloud-synced personal dictionary, (c) n-best rescoring ("accent confidence
scoring"). No accent-specific magic.

**Independent benchmark reality:** Apple's SpeechAnalyzer measures ~14.0% WER on
real conversational audio (Argmax) — between whisper *base.en* (15.2%) and
*small.en* (12.8%), i.e. whisper-small-class, far from whisper-large-v3. All ASR
degrades on non-native speech and larger models degrade less. **The acoustic model
is the gap.** On-device Whisper large (our branch) is the correct fix.

## Finding 2: some of "our" ASR errors are self-inflicted (pipeline audit)

Ranked, with the recognizer entirely blameless:

1. **`applySpokenPunctuation` destroys real words, ON by default** — literal
   "period"/"comma"/"colon"/"semicolon" are blindly replaced with symbols in
   Clean Writing/Email at standard strength ("during that period we…" → "during
   that. we…"). Reads exactly like an ASR error. Gate or remove.
2. **LLM cleanup runs on every dictation (macOS 26) and its guard can't catch
   word substitutions** (pill→peel passes: guard only checks negations/digits/
   30% overlap). Accented input invites more "corrections". For benchmarking,
   rule-only mode is mandatory. Also: the Anthropic provider path has NO guard
   and no preamble strip at all.
3. **`contextualStrings` are inert on `SpeechTranscriber`** — Apple staff confirm
   (dev forums 811083, 801877) only `DictationTranscriber` honors them. Our
   vocabulary biasing on the Apple path does nothing, and the `try? setContext`
   swallows any error. All of Apple's accent levers (`.atypicalSpeech`,
   `.shortForm`, custom LM w/ X-SAMPA pronunciations) attach ONLY to
   `DictationTranscriber` (the older dictation model) — a trade worth A/B'ing,
   but the new engine's raw model is stronger; probably a dead end vs Whisper.
4. **"Raw" mode isn't raw** — VocabularyReplacer + whitespace normalization run
   before the raw early-return, corrupting the WER benchmark protocol.
5. **Raw text is stored but never shown** — user can't distinguish ASR errors
   from cleanup errors. Cheapest diagnostic fix in the codebase.
6. Smaller: fixed 0.8s pre-roll can transcribe pre-keypress speech (insertions);
   disk I/O + allocation on the audio render thread risks dropped buffers;
   0.4s min-hold discards quick real utterances; mic-device setting is dead code.

**Confirmed NOT problems** (don't chase): capture format (CAF float32 native-rate
is lossless; both engines resample correctly), no AGC/voice-processing mangling,
no volatile-result interleaving, n-best re-rank can't degrade, trailing drain is
adequate, filler removal is safely narrow.

## Finding 3: the Whisper branch had a fatal config bug (now fixed)

Model name `"large-v3-turbo"` matches NO folder in argmaxinc/whisperkit-coreml —
first dictation would fail after the ~1GB download. OpenAI's turbo lives under
the `v20240930` names. Now `openai_whisper-large-v3-v20240930_turbo`, with
UserDefaults override `whisperModelVariant` for the A/B; the accuracy ceiling is
`openai_whisper-large-v3_turbo` (FULL large-v3, Argmax-optimized; ~1 WER better
on accents, bigger/slower). Decoding per research: force en + prefill prompt, no
language detect, temp fallback ×3, no timestamps, suppressBlank, no VAD chunking
on ≤30s clips. `promptTokens` vocabulary biasing exists but was broken before
WhisperKit PR #514 — verify pinned version before using.

## The plan to reach Wispr parity (ranked)

1. **DONE (branch): background model download + progress UI + Apple fallback**
   — Whisper mode is now actually usable; validate on live mic.
2. **Measure honestly**: fix Raw mode bypass, show rawText in history, then run
   `Scripts/wer.py` Apple-vs-Whisper on the user's voice (protocol in
   docs/ACCURACY_BENCHMARK.md). Decision rule per parity plan §4.
3. **Kill self-inflicted errors**: spoken-punctuation gating; cleanup guard in
   the pipeline for both providers.
4. **Replicate Wispr's context loop locally (post-Whisper)**: feed vocabulary +
   AX-harvested screen nouns as Whisper promptTokens; auto-learn dictionary from
   user edits; two-engine disagreement rescoring via the on-device LLM.
5. **Latency parity** (already planned §3.3): warm LLM session, tier/skip
   cleanup, two-phase delivery.

Sources: wensenwu.com/thoughts/wispr-flow-investigation · baseten.co/resources/customers/wispr-flow ·
wisprflow.ai/research/supporting-languages · argmaxinc.com/blog/apple-and-argmax ·
developer.apple.com/forums/thread/811083 · github.com/argmaxinc/argmax-oss-swift issues/372, pull/514
