# Research: Closing the Remaining Transcription Gap (Round 2)

Research date: 2026-08-20. Scope: raw transcription accuracy only, on-device only,
one accented speaker, starting point 12.07% WER (8-sentence read corpus) vs
Wispr's confounded 7.8%. Everything already measured (VAD chunking, silence
trimming, biasing, large-v3 tie, normalization tie, Parakeet rejection, prompt
rewording, prosody splitting) is treated as settled and NOT revisited here.
WhisperKit claims below were verified by reading the pinned v1.1.0 source in
`.build/checkouts/WhisperKit`, not from docs. Speculation is marked.

---

## (a) Executive summary — plain English

We already run two listeners on every dictation — Whisper and Apple's — and
today we only use the second one as a lie detector. The research says that is
the biggest thing we are sitting on: letting the two listeners vote, with a
referee for disagreements, has cut errors 8–11% in published head-to-head
tests, and it can be built so no word ever appears that neither listener heard.
Second: two settings inside Whisper's decoder were checked in its actual source
code — "beam search" (the setting people usually reach for) literally does not
exist in our library, but a hidden give-up threshold DOES exist and may be
silently throwing away hard first words; testing it costs an afternoon.
Third: teaching Whisper his voice from his own corrected dictations is real and
doable on this Mac with today's tools, but the evidence says ~30 samples is too
few to help and could hurt — keep collecting; at roughly an hour of corrected
audio it becomes a serious weekend experiment with a real shot at the largest
single gain of anything in this document.

---

## (b) Ranked lever table

| # | Lever | Expected WER effect (cited) | Cost to build | Risk to verbatim rule | Proof on his corpus |
|---|---|---|---|---|---|
| 1 | **Dual-engine fusion with a tie-breaker** (ROVER-2: align both transcripts, keep Whisper unless the referee overrules) | 2-system ROVER with plain voting **hurts** (13.5→13.8%, 17.1→18.9%); with an LM tie-breaker it gave **−8.1% and −11.1% relative** (Schwenk & Gauvain 2000). Constrained selection among hypotheses gave **−11–12% relative** (N-best T5). On 12.07% that is ~11.0% IF Apple's engine is competitive on his voice — gate on measurement, see right | Medium: edit-distance word alignment + tie-break policy; the arbiter plumbing already exists | **Low** if the one inviolable rule is kept: output words must come verbatim from one of the two engines, substitutions only (no insertions/deletions). DualEngineVoting.swift already encodes this rule — extend it, don't replace it | **Step 1 (hours, zero risk):** decode the archived `ab-2026-08-19` corpus + capture corpus with the Apple engine alone; score Apple-only WER and the ORACLE fusion WER (pick the better word at each disagreement). Oracle gap = the whole ceiling for this lever. If Apple-only WER is ≥2× Whisper's, expect little (combining much weaker systems can raise error — Schwenk Fig. 1) |
| 2 | **Decoder A/B trio** (settings verified in v1.1.0 source) | Unquantified — but `firstTokenLogProbThreshold` (default **−1.5**, we never set it) is LIVE: if the FIRST sampled token's logprob is below it, the whole window decode aborts and retries at higher temperature (TextDecoder.swift:674, DecodingFallback in Models.swift). With our `temperatureFallbackCount=1`, two bad first tokens = a truncated/empty segment. This is a concrete candidate mechanism for the missing-words class on accented first words. A/B: `nil` vs −1.5 vs −2.5; also fallbackCount 1 vs 3 | Trivial: set options, replay archived corpus | None — pure decode-path, offline-measured | Paired WER on the archived corpus; specifically count empty/short decodes and missing-word errors per arm |
| 3 | **Wire PersonalConfusions + phonetic vocab matching** (built/designed, unwired) | Entity-class lever: phonetic post-correction is the standard noisy-ASR entity fix; biasing-style B-WER effects (OWSM-Biasing: B-WER −11.6 pts, overall −0.9). Overall WER moves little; the words he cares about move a lot | Low — code exists | Low-medium, already designed bounded (vocab-only targets, ≥2 sightings, substitutions only) | Replay over ≥100 real dictations: zero false rewrites; B-WER on entity list improves |
| 4 | **Personal LoRA fine-tune of turbo on his corrected pairs** | Speaker-adaptive LoRA: **−24.2% relative** (LibriSpeech-SA); accented fine-tunes report −44% relative (non-native learners, whisper-small, 50 h); dysarthric case study: gains are largest early but used **1.4 h minimum**; no published win from <1 h that I found. At N=30–200 pairs (10–25 min): **speculation, plausibly −5–15% relative, with real overfit/regression risk** | High: training run + CoreML re-export + regression gating (see (c)) | None at inference — it is still the same ASR emitting what it hears. Risk is REGRESSION (hallucination behavior can shift) → full phantom/WER gate before install | Hold out 20% of pairs never trained on; paired WER + phantom-rate + entity recall on held-out set vs stock turbo |
| 5 | **2-best constrained LLM rescoring** (Apple Foundation Models picks Whisper's or Apple's sentence — choose-only, never generate) | N-best T5: constrained decoding **−11–12% relative**, and constrained BEAT unconstrained (2.53 vs 2.67) — the no-hallucination version is also the more accurate one. But that was 10-best from one strong engine; ours is 2-best cross-engine → **smaller, speculative**. GEC literature's known failure: fluent-but-wrong choices and phantom entities under unconstrained generation — which choose-only structurally prevents | Medium: FoundationModels guided generation with a two-case @Generable choice | Medium if sentence-level (a whole wrong sentence can win); low if only used as the tie-breaker inside lever 1 (word-level) — recommended form | Offline replay: on the corpus, does the LLM referee pick the lower-WER hypothesis more often than confidence alone does? |

**Not levers (checked and closed):**
- **Beam search / topK in WhisperKit 1.1.0: does not exist.** `BeamSearchTokenSampler.update()` is `fatalError("Not implemented")` (TokenSampler.swift:254-289) and `TranscribeTask` always instantiates `GreedyTokenSampler` (TranscribeTask.swift:337). `topK` (default 5) only affects the stochastic sampling used during temperature-fallback retries. Any plan that needs beam search (e.g. Whisper-LM shallow fusion) is dead on WhisperKit today.
- **`noSpeechThreshold` is STILL dead config in v1.1.0** — `noSpeechProb` remains hardcoded 0 with a TODO (TextDecoder.swift:817). The CLAUDE.md trap note stays true after the upgrade.
- `sampleLength` default = 448 (max token context) — a cap, not an accuracy knob for ≤30 s dictations.
- `compressionRatioThreshold` (2.4) and `logProbThreshold` (−1.0) are live fallback triggers in 1.1.0; defaults match the community recipe — leave them.
- Dead ends per the brief (measured, do not revisit): full large-v3, audio normalization, prompt rewording, Parakeet, prosody splitting.

---

## (c) Personal fine-tuning: verdict and toolchain

**Verdict: GO — but not yet. NO-GO at today's N≈30–50 pairs; GO as an offline
weekend experiment once the capture corpus reaches ~500 corrected pairs / ≥60
minutes of audio.** The toolchain exists end-to-end on this Mac; the binding
constraint is data volume, not tooling. Every published win uses ≥1 h; below
that the risk of overfitting his read-corpus style and regressing hallucination
behavior outweighs the expected gain. The corpus is already growing
automatically (truth.py + capture retention), so the cost of waiting is zero.

**Toolchain (validated pieces, in order):**

1. **Train — PyTorch + PEFT LoRA on MPS** (most established path):
   ```
   python3 -m venv ~/ft && source ~/ft/bin/activate
   pip install torch torchaudio transformers datasets peft accelerate jiwer soundfile
   ```
   `WhisperForConditionalGeneration.from_pretrained("openai/whisper-large-v3-turbo")`
   + `LoraConfig(r=16, target_modules=["q_proj","v_proj"])`, Seq2SeqTrainer,
   `device="mps"`, 3–5 epochs max (overfit guidance from the fine-tune
   community), fp32 or bf16 (fp16 on MPS is flaky). Turbo is 809 M params;
   LoRA trainable params are ~10–20 M, so weights+optimizer+activations fit
   comfortably in 32 GB unified memory. Wall-clock for 500 pairs × 4 epochs:
   **estimate 1–4 h on an M-series Max — our estimate, not literature.**
   Alternative: `mlx-tune` (ARahim3/mlx-tune) ships native MLX Whisper LoRA
   (`FastSTTModel.get_peft_model`) — younger tool, turbo support unconfirmed;
   note Apple's own `mlx-whisper` is **inference-only**, no training.
2. **Merge**: `model = peft_model.merge_and_unload(); model.save_pretrained("whisper-turbo-yoni")`
   (plus processor/tokenizer files) → a standard HF-format checkpoint.
3. **Convert — whisperkittools** (argmax's official tool for exactly this):
   ```
   pip install whisperkittools
   whisperkit-generate-model --model-version <checkpoint> --output-dir Models/
   ```
   The README's stated purpose includes deploying "your own fine tuned versions
   of Whisper" and third parties have shipped fine-tuned large models this way
   (e.g. `fredchu/breeze-asr-25-whisperkit-coreml`). **What can break:**
   (a) `--model-version` is documented against HF repo ids; local-path support
   is unconfirmed — verify in source; if it insists on a Hub repo, do NOT
   upload (LoRA weights trained on his voice are personal data leaving the Mac
   — privacy call is Yoni's, default no) — patch the tool locally instead;
   (b) WhisperKit resolves tokenizer files by model name — the custom folder
   must carry them; (c) `WhisperModelManager` matches HF folder names exactly
   (the known `-v20240930` turbo trap) — a custom variant name needs a config
   hook, which `whisperModelVariant` already provides.
4. **Gate before it ever touches the app**: held-out 20% split (never trained
   on), paired WER + entity recall + phantom rate vs stock turbo on identical
   audio; ship only on a significant win with no phantom regression.

---

## (d) Simplest safe dual-engine fusion (pseudocode)

Design principle (from the 2-system ROVER result): with two engines, EVERY
disagreement is a tie — plain voting is meaningless and measurably harmful; all
value is in the tie-breaker. And the safety rule is structural: the output may
only contain words an engine actually produced for this audio, substitutions
only. This is `DualEngineVoting.reconcile` grown an alignment and a referee.

```
fuse(whisper, apple, vocab, confidence):
    # 1. Align word sequences by minimum edit distance (not the current
    #    equal-length zip — that is why voting almost never fires today).
    ops = align(whisper.words, apple.words)     # match | substitute | ins | del

    out = []
    for op in ops:
        match           -> out += whisper.word          # agreement ≈ correct
        ins | del       -> out += whisper's side        # NEVER add/remove words:
                                                        # structure disputes always
                                                        # resolve to the primary
        substitute(w,a) ->
            # Tie-break ladder, strongest signal first. Default: keep w.
            if norm(a) in vocab and norm(w) not in vocab:   out += a   # existing rule
            elif norm(w) in vocab:                           out += w
            elif whisper.wordLogProb(w) is LOW and referee_margin(w, a) > θ:
                 out += a       # referee = on-device LM scoring BOTH full
                                # sentences (choose-only; guided generation
                                # two-case choice, or a local n-gram LM);
                                # fires only on decisive margins
            else:                                            out += w
    return join(out)            # then CleanupGuard downstream, as always
```

Rollout in three measured stages, each gated on the archived corpus:
1. **Measure the ceiling** (no product change): Apple-only WER + oracle-fusion
   WER on the same audio. If the oracle gain is <1 point, stop here — the
   lever is empty for his voice and that is a result.
2. **Alignment + vocab-only tie-break** (today's rule, freed from the
   equal-length restriction). Replay-gated: zero regressions on agreements.
3. **Referee tie-break** on low-confidence substitutions only, margin-gated.
   Count referee firings and wins/losses per session log.

Latency note: stage 2–3 needs the Apple transcript for every dictation, not
just arbiter cases — Apple SpeechAnalyzer already transcribes while recording,
so the marginal cost is reading a result that mostly exists, not a second
decode. Verify in the session log before assuming.

---

## (e) Sources

**System combination / fusion**
- ROVER original (44.9→39.4%, 5 systems): https://www.nist.gov/publications/post-processing-system-yield-reduced-word-error-rates-recognizer-output-voting-error
- Schwenk & Gauvain 2000 — THE 2-system numbers: plain 2-ROVER hurts (13.5→13.8 / 17.1→18.9); LM tie-break −8.1% / −11.1% relative; combining weak systems can hurt: https://www.vocapia.com/publim/icslp00_holger.pdf
- ROVER algorithm/tooling: https://github.com/usnistgov/SCTK/blob/master/doc/rover/rover.htm
- Confidence-based combination & quality estimation (+1.6 abs over best single, TED): https://arxiv.org/abs/1706.07238 · https://www.sciencedirect.com/science/article/abs/pii/S0885230816300328
- Cross-adaptation E2E+hybrid combination (up to −28.9% rel, research systems): https://arxiv.org/pdf/2206.11596
- Encoder-fusion of Whisper+wav2vec2 (rare-word gains; training-heavy, not our path): https://arxiv.org/pdf/2606.10853

**WhisperKit v1.1.0 decoder (source-verified, `.build/checkouts/WhisperKit`)**
- Beam stub: `Sources/WhisperKit/Core/Text/TokenSampler.swift:254-289`; greedy-only: `Core/TranscribeTask.swift:337`
- firstTokenLogProbThreshold abort: `Core/TextDecoder.swift:674` + `DecodingFallback` in `Core/Models.swift`
- noSpeechProb hardcoded 0 (TODO): `Core/TextDecoder.swift:817`; defaults: `Core/Configurations.swift:196-244`
- Repo/releases: https://github.com/argmaxinc/WhisperKit · https://github.com/argmaxinc/whisperkittools

**Rescoring / constrained correction**
- N-best T5 — constrained decoding −11–12% rel, constrained beats unconstrained: https://arxiv.org/pdf/2303.00456
- HyPoradise GER ceiling (big LLMs): https://arxiv.org/abs/2309.15701
- GEC hallucination failure modes + verification staging: https://arxiv.org/pdf/2505.24347 · https://ar5iv.labs.arxiv.org/html/2307.04172

**Personal adaptation**
- Speaker-adaptive LoRA −24.2% rel: https://arxiv.org/pdf/2408.03979
- Dysarthric foundation-ASR case study (gains-vs-data curve, 1.4 h floor, full FT > LoRA under big mismatch): https://arxiv.org/pdf/2606.31722
- Non-native learners fine-tune −44.2% rel (whisper-small, 50 h): https://arxiv.org/pdf/2407.04280
- UK regional dialect adaptation: https://arxiv.org/pdf/2501.08502 · Accented ATC adaptation: https://arxiv.org/pdf/2502.20311
- Overfit guidance (≤4–5 epochs, augmentation): https://github.com/openai/whisper/discussions/759
- MLX training tools: https://github.com/ARahim3/mlx-tune (Whisper LoRA) · mlx-whisper is inference-only
- Fine-tuned→WhisperKit conversions in the wild: https://huggingface.co/fredchu/breeze-asr-25-whisperkit-coreml
