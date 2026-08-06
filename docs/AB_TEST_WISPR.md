# Proving VoiceFlow transcription = Wispr — objective A/B test

The question "is our transcription as good as Wispr?" is answered by a number, not
an opinion: the **Word Error Rate (WER)** of each app on the *same* script. This is
the exact method speech-recognition researchers use.

## The one rule: measure in RAW mode

Set VoiceFlow to **Raw** mode for this test. Raw = the recognizer's exact words with
NO cleanup. That isolates *transcription* (did it hear the words) from *formatting*
(cleanup turning "three thousand dollars" into "$3,000", which would otherwise count
as errors and understate accuracy).

## Protocol

1. **VoiceFlow → Raw mode.** Cursor in a Note.
2. Read **each** sentence below out loud, once, at a normal pace. Keep VoiceFlow's
   output in one note.
3. Say the **same** sentences into **Wispr**. Keep its output separate.
4. Score each app against the reference:

```bash
python3 Scripts/wer.py --ref "REFERENCE SENTENCE" --hyp "WHAT THE APP WROTE"
```

Run it once with VoiceFlow's text as `--hyp`, once with Wispr's. Compare the two
WER numbers.

## The script (reference = ground truth)

Read these exactly. They're loaded with the hard cases (homophones, proper nouns,
tricky words) that separate a real engine from a toy:

1. `Their proposal was accepted and they were thrilled with the results.`
2. `I would like to schedule a meeting for Thursday at eleven fifteen in the morning.`
3. `Please send the invoice to accounts payable before the end of the day.`
4. `It is not too late to change the pill order for the clinic on Main Street.`
5. `Doctor Smith reviewed the report and found two errors on page seven.`

## Reading the result

- **VoiceFlow WER vs Wispr WER within ~1–2 points → they are equivalent.** That is
  the proof. (Both should land near 2–5% on clean speech in a quiet room.)
- If VoiceFlow is clearly worse, the aligned diff shows *which* words — paste it and
  we fix that class (custom pronunciations, vocabulary, or an audio issue).
- Do all 5 sentences and average, or repeat a few times — more samples = more
  confidence. One sentence is noisy; five is a signal.

## Why this is trustworthy

`Scripts/wer.py` is ~50 lines of standard word-level edit-distance — you can read it,
and it treats both apps identically. It normalizes case and punctuation so it scores
*words*, not formatting. Nothing about it favors VoiceFlow. The number is the number.
