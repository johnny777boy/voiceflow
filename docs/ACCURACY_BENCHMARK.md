# VoiceFlow Accuracy Benchmark — is it Whisper-level?

Two ways we verify VoiceFlow is professional-grade, not "mediocre": an automated
suite that proves the formatting never garbles text, and a repeatable real-world
accuracy test you run in 5 minutes.

## A. Automated proof (formatting robustness) — already passing

The deterministic cleanup layer is covered by golden tests, including regression
guards for every word-garbling / bad-capitalization bug we fixed:

```bash
cd <repo> && swift run VoiceFlowTests   # expect: All 85 tests passed
```

These prove, on every build, that "run the command" never becomes "run the,nd",
that "3.14" and "U.S." don't trigger wrong capitalization, and that "you know" /
"i mean" are never deleted. If any regress, the build fails.

## B. Real-world accuracy test (transcription) — 5 minutes

Speech accuracy is measured as **Word Error Rate (WER)**: the percent of words
wrong (substitutions + insertions + deletions). Reference points on English:

| Engine | WER (clean speech) |
|---|---|
| Apple SpeechAnalyzer (VoiceFlow) | ~2.1% |
| OpenAI Whisper Small | ~3.7% |
| Legacy macOS dictation (old) | ~9% |

**Target: ≤ 5% word errors = professional / Whisper-level.**

### The passage (≈100 words — read it exactly)

> The quick brown fox jumps over the lazy dog near the riverbank. I would like to
> schedule a meeting for March third at eleven fifteen in the morning. Please send
> the invoice to accounts payable before Friday. Their proposal was accepted, and
> they were thrilled with the results. We reviewed version 3.14 of the report and
> found two errors on page seven. Dr. Smith from the U.S. office will join by
> phone. It is not too late to change the pill order for the clinic. Thank you very
> much for your patience and continued support throughout this process.

### How to score

1. Set VoiceFlow mode to **Raw** (measures the transcription engine only, no cleanup).
2. Put the cursor in a note. Hold the hotkey, read the passage once at a normal pace,
   release.
3. Compare the output to the passage above. Count wrong words: each wrong,
   missing, or extra word = 1 error.
4. `WER% = (errors / 100) × 100`.
   - **0–5 errors:** Whisper-level. Ship it.
   - **6–10:** good; the custom-vocabulary + SpeechDetector phase (roadmap Phase 1)
     will close the gap.
   - **>10:** something's off (mic input, wrong locale, background noise) — report it.

### Then test the full experience

Switch mode back to **Clean Writing** and read the passage again. Now judge
**formatting**: sentences start capitalized, end with the right punctuation, no
stray spaces before commas/periods, "3.14" and "U.S." intact, numbers sensible.

### Watch words (homophones / hard cases in the passage)

These are the words that separate a real engine from a toy — check them
specifically: their/there/they're, pill (not peel), March third, eleven fifteen,
version 3.14, U.S., page seven.

## Logging (optional, for diagnosis)

Live trace while testing:

```bash
log stream --level debug --predicate 'subsystem == "com.voiceflow.dictation"'
```

You'll see `engine: SpeechAnalyzer`, `cleanup: on-device Foundation Models`, and
`SA transcribed N chars` per dictation, confirming the right path ran.
