# Codex Brief — the remaining TRANSCRIPTION gap (round 2, evidence-based)

Repo: github.com/johnny777boy/voiceflow · branch `feature/accuracy-parity`
(pushed) · folder `VoiceFlow-accuracy`. Build: `swift build -c release`
(0 warnings) · tests: `swift run VoiceFlowTests` (242 pass).

## What changed since your last review — every one of your calls, resolved

1. **You said the timings/chunking config was the real mistake. You were right.**
   `chunkingStrategy = .none` was the run-on cause: his 152/179/189-word
   dictations decoded as ONE sentence each; with `.vad` they come back as
   3/11/3 sentences, WER unchanged (12.07%) on the 8-sentence reference.
   Shipped ON (`WhisperKitTranscriber.swift`, dev switch `whisperVADChunking`).
2. **Your prosody-segmentation idea was tested and does NOT fit this speaker:**
   72 words in 30s with only two ≥250ms pauses, both mid-clause. Word timings
   are now available (`VoiceFlowBench --timings <file>`) if you want the data.
3. **Parakeet was benchmarked on his audio and REJECTED**: 15.52% WER vs our
   12.07%, entity recall 66.7% vs 83.3% (4x faster, irrelevant). Dependency
   removed; code in git history (`aa3f975`).
4. **Biasing is ON** (echo-framing hole closed first — `looksLikePromptEcho`
   now catches the prompt framing, not just terms). Entity recall 50%→83%.
5. **Leading AND trailing silence trimming shipped** (`LeadingSilence`):
   19.0%→13.79% WER, and the trailing-silence "Thank you." phantom is gone.
6. **PersonalConfusions built** (unwired): exact whole-word lookup learned from
   his corrections, ≥2 sightings, substitutions only (insertions/deletions
   excluded by design). `Sources/VoiceFlowCore/Learning/PersonalConfusions.swift`.
7. `DevSwitch` fixed a real trap: `-flag NO` via NSArgumentDomain is a STRING,
   `as? Bool` fails, switches read their default. An A/B ran both arms
   identical because of this.

## Current measured state (his voice, 8 read sentences + live spot checks)

  VoiceFlow now:   12.07% WER, entity recall 83.3%
  Wispr Flow:       7.8% WER (confound: his SECOND reading went to Wispr)
  Sample resolves ~11 points; treat the 4-point gap as directional only.

The owner's verdict: the four failure classes (missing/extra/wrong words,
run-ons) are much rarer but STILL OCCUR, and he wants the raw transcription
itself closer to Wispr. That is the question this round.

## The question for you

Given everything above is measured and shipped, what is the NEXT set of
concrete, on-device levers for RAW TRANSCRIPTION accuracy on one accented
speaker — and in what order? Specifically judge:

a) **Dual-engine fusion.** We run BOTH Apple SpeechAnalyzer and Whisper per
   dictation already (arbiter exists for phantoms/echo). ROVER-style or
   confidence-based word-level fusion of the two transcripts — real gains or
   research toy? What is the simplest safe version?
b) **Decoder settings still on the table**: beam vs greedy in WhisperKit 1.1.0,
   temperatureFallbackCount, firstTokenLogProbThreshold (-1.5 default we never
   set), sampleLength. Which are worth a measured A/B on his corpus?
c) **Offline personal adaptation**: we now HAVE his audio + corrected
   transcripts accumulating (~30 clips + growing, `truth.py` corpus). Is any
   offline fine-tune path (LoRA on turbo, re-exported to CoreML) actually
   practical on an M-series Mac, or still fantasy? Be concrete about tooling.
d) **PersonalConfusions wiring**: where in the pipeline (post-ASR pre-cleanup?),
   and what additional guard conditions would YOU require before it may fire?
e) Anything in our decode path you'd still flag after reading
   `WhisperKitTranscriber.swift` end to end at head.

Constraints unchanged: on-device only, verbatim guard stays, no auto-edits of
his words, every change WER-gated on his corpus
(`~/Library/Application Support/VoiceFlow/ab-2026-08-19/` + bench tools).

Verdict format: ranked list with expected effect size, cost, and the measurement
that would prove each one. Flag anything you consider a dead end so we do not
spend a session on it.
