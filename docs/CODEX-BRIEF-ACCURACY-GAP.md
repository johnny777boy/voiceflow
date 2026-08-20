# Codex: we cannot close the last of an accuracy gap. Find what we are missing.

This is not a code review. It is a request for a **better idea**, from someone
who has not spent the last day inside this problem and cannot inherit our
assumptions. We have measured a lot and fixed some of it; the owner still says
the output is not usable, and he is right. We would like your diagnosis.

## The product

macOS push-to-talk dictation, SwiftPM, macOS 26, on-device only. Audio never
leaves the Mac — that is the product's moat and is not negotiable. Engines:
WhisperKit 1.1.0 (`openai_whisper-large-v3-v20240930_turbo`) with Apple's
SpeechAnalyzer as fallback and second opinion. Optional cleanup: Apple
FoundationModels on-device LLM, behind a strict bidirectional guard
(`CleanupGuard`) that rejects any edit which adds, drops, or substitutes a word.

The owner is a **non-native English speaker** (Israeli, remodeling contractor).
He dictates all day. His benchmark is **Wispr Flow**, which he says is near
perfect for him.

## What the owner says is wrong — his words, four issues

1. **Missing stuff** — words he said that do not appear.
2. **Adds stuff** — words he never said that do appear.
3. **Wrong words** — misheard substitutions.
4. **"The way the sentences are combined"** — run-on formatting; it "doesn't
   look good" written down.

## What we have MEASURED (all on his own voice, audio archived)

Eight sentences he read into VoiceFlow and then into Wispr Flow, scored against
the script (`docs/ab-script.txt`, audio + all transcripts in
`~/Library/Application Support/VoiceFlow/ab-2026-08-19/`):

| system | WER |
|---|---|
| VoiceFlow, this morning | 19.0% |
| Wispr Flow | **7.8%** |
| VoiceFlow + leading-silence trim | 13.79% |
| + context biasing (built, still OFF) | 12.07% |

Live re-test after the trim shipped: his sentence 1 went 66.7% -> 16.7% WER,
**better than Wispr's 25.0% on the same sentence**.

### What WORKED, and why

- **Trimming leading silence.** Every recording of his begins with 1.6-2.7s of
  near-silence (he holds the key, then speaks). Whisper mis-decodes across it:
  "Codex, verify branch before merging to domain. Thank you." became "Ask Codex
  to verify the branch before we merge it to domain." Eight errors to one.
- **Trimming trailing silence.** One second of it at the end of a 32-second
  dictation made Whisper append "Thank you." — on the dictation where he was
  telling us the app invents words. Removing the second removed the phantom.
- **Context biasing.** Entity recall 50% -> 83% ("CloudCode" -> "Claude Code",
  "to domain" -> "to the main"). Overall WER barely moves, as the literature
  predicts.

### What FAILED — do not suggest these, they are measured dead ends

- **A bigger model.** Full `openai_whisper-large-v3` (32-layer decoder) on
  IDENTICAL audio scored 19.8% against turbo's 19.0%. Better on three sentences,
  worse on two, catastrophic on one ("Chad GPTs and Clot Code"). The published
  ~1.1-point accented-English gap did not materialise for him.
- **Capture level.** His recordings peak at 0.15-0.22 where healthy speech peaks
  0.5-0.9. Peak-normalising and re-decoding scored **identically** (18.97% both).
  WhisperKit normalises internally.
- **Prompt wording for run-ons.** Three variants measured over 25 real
  dictations: the long explicit instruction made the small on-device model do
  LESS (longest sentence 86->86 words instead of 86->77), the short one was a
  no-op. The model will not segment his speech however it is asked.

## Where we are stuck

**~4 points of WER, and the fourth issue entirely.** We have no theory left for
either. Specifically:

1. **The residual mis-hearings are narrow and phonetic.** "We need to dig a new
   well behind the garage" -> "We need to dig. You walk behind the garage".
   Everything around the failing run is perfect; Wispr gets it exactly. Biasing
   helps named entities, not this.
2. **Run-on formatting is unsolved.** Delivered text carries 6.4% discourse
   markers (like/so/actually/I mean), a 73-word longest sentence, 5 sentences
   over 40 words. The on-device LLM refuses to segment. Deterministic
   segmentation is the only remaining candidate and has not been attempted.
3. **We cannot separate model quality from the recording itself.** Wispr records
   its own audio; we cannot feed it ours. Our 11-point measurement compared his
   FIRST reading (to us) against his SECOND (to Wispr), so part of it is
   practice effect. We do not know the true gap.

## The questions we want answered

1. **Is `large-v3-turbo` the wrong engine for a non-native speaker, and is there
   a better on-device option?** Parakeet/Canary via CoreML or MLX, distil-whisper,
   a fine-tune? We need something that runs on Apple Silicon, offline, at
   conversational latency. Concrete recommendations with evidence, please.
2. **Speaker adaptation.** He is ONE user with hours of his own audio and
   growing ground truth. Is on-device personalisation (LoRA, or a learned
   phonetic correction layer) realistic here, and what is the cheapest version
   that would move his WER?
3. **Decoder configuration.** We set `temperatureFallbackCount = 1`,
   `usePrefillPrompt = true`, `chunkingStrategy: .none`, suppress tokens built
   per model. `noSpeechThreshold` is dead config in 1.1.0 (`noSpeechProb` is
   hardcoded 0 in `TextDecoder.swift`). `firstTokenLogProbThreshold` defaults to
   -1.5 in 1.x and we never set it. **Are we leaving accuracy on the table in
   the options themselves?** See `Sources/VoiceFlowWhisper/WhisperKitTranscriber.swift`.
4. **Are we mis-handling the AUDIO before the decoder?** We capture 48kHz
   Float32 mono via SpeechAnalyzer's recorder and let WhisperKit resample. Is
   there loss there? Should we run a real VAD (Silero-class) rather than our
   energy heuristic? Would per-utterance chunking beat one long clip? His clips
   run up to 32 seconds with long internal pauses.
5. **Run-on segmentation.** Given a verbatim-fidelity rule that forbids adding,
   dropping or reordering words, what is the correct way to insert sentence
   boundaries into 30 seconds of spontaneous non-native speech? Note our guard
   now rejects splits that sever a clause ("Call me before the meeting" may not
   become "Call me." + "Before the meeting…").
6. **Is our whole framing wrong?** Wispr streams to server-side ASR with the
   accessibility tree and screen contents injected as context, plus a fine-tuned
   formatting LLM. We refuse the cloud. **Is on-device parity actually
   achievable, or should we be advising him differently?** An honest "no" is
   more useful to us than an encouraging maybe.

## Ground rules for your answer

- **On-device only.** Any cloud proposal is out, however good.
- **Verbatim fidelity outranks polish.** Never add, drop, or substitute a word.
  Wispr shipped the opposite and it was their top complaint from 700+ users;
  our guard exists to make it impossible.
- **Every accuracy claim must be measurable** on his archived audio with
  `Scripts/wer_compare.py` (paired bootstrap, entity recall). Tell us how you
  would measure your suggestion, not only what it is.
- **Be blunt about what we got wrong.** We would rather hear that the last day
  was misdirected than be agreed with.

## Where to look

- `Sources/VoiceFlowWhisper/WhisperKitTranscriber.swift` — decode path, options,
  energy gate, phantom filter, arbiter.
- `Sources/VoiceFlowCore/Transcription/LeadingSilence.swift` — the trim that worked.
- `Sources/VoiceFlowCore/Cleanup/CleanupGuard.swift` — the verbatim guard.
- `Sources/VoiceFlowCore/Context/TranscriptionContext.swift` — biasing prompt.
- `docs/RESEARCH-WISPR-PARITY-PLAN.md` — the research behind the current plan.
- `Scripts/wer_compare.py`, `Sources/VoiceFlowBench/main.swift` — measurement.

Build: `swift build -c release` (0 warnings). Tests: `swift run VoiceFlowTests`
-> "All 235 tests passed".
