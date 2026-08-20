# VoiceFlow Speed Strategy — research synthesis (2026-08-10)

Three parallel research passes (market, pipeline audit, on-device streaming
physics) + first real data from the per-stage instrumentation. Standing rule
gating all of it (Yoni): **speed may never cost quality** — every change is
WER-gated on his voice; safety machinery is not a latency budget.

## The measured bill (instrumented rows, 2026-08-10)

All sampled dictations ran on the **Apple engine** (see "Surprise finding").

| Stage | Cost | Notes |
|---|---|---|
| Transcribe | 0.5–1.7s (~0.9 median) | record-then-transcribe; starts only at release |
| LLM cleanup | 0.9–1.7s when it runs; 0 on fast path | the single biggest line item on most dictations |
| Arbiter | 0.0 in every row | only exists on the Whisper path, which isn't running |
| Insert + overhead | ~0.15s | |

Short fast-path dictations already land at 0.6–0.9s total. The bill is ~50/50
decode vs cleanup. The audit's arbiter-dominance hypothesis applies only when
Whisper is active — keep it on file for when Whisper re-engages.

## ⚠️ Surprise finding — Whisper is silently not running

`useWhisperEngine = 1`, model fully present on disk
(`openai_whisper-large-v3-v20240930_turbo`), yet every instrumented dictation
shows `engineUsed = apple`. So `whisper.isReady` is false at dictation time —
the model is not loading into memory (load failure, or bootstrap not firing
after the day's many relaunches). **Yoni has been dictating on the
lower-accuracy engine all day without knowing.** Investigate FIRST — this is a
quality bug under the standing rule, and it also decides which latency plan
applies. (The engineUsed column paid for itself on day one.)

## Market findings (full report in session transcript)

- Feels-instant threshold: **<1s**; complaints start >2s. We measured ~2.1s.
- Target for a sellable on-device product: **<1s short replies, ~1.5s
  paragraphs, hard ceiling 2s**.
- Fast on-device competitors (Superwhisper, VoiceInk, Handy) converged on
  **Parakeet-TDT-0.6B** — ~100x realtime, better clean-English WER than
  large-v3, structurally cannot hallucinate on silence — BUT reviews give
  Whisper the edge on accented speech, so it is NOT our primary (rule: no
  accuracy loss). Possible future roles: instant-draft engine, faster arbiter.
- Privacy demand is real and loud (Wispr's 2025 screenshot scandal; HIPAA/legal
  segments; "local only is an absolute requirement" sentiment). Positioning:
  "under a second for short replies, ~1.5s for paragraphs — and your voice
  never leaves your Mac." Pricing evidence favors one-time license $39–99.
- No on-device competitor decodes during the hold with a large-class model —
  open differentiator.

## The plan (ordered; each step gated by ritual + WER on Yoni's voice)

0. **Fix the Whisper-not-engaging bug** (quality first).
1. **Cleanup latency package** (S, no audio risk): live-test two-phase delivery
   (built, off); prewarm the REAL instructions (today prewarms hardcoded
   .cleanWriting/.standard — a warm session that may not transfer); revisit
   fast-path tiers. Removes ~1s of FELT latency on every LLM-cleaned dictation.
2. **Waste cuts from the audit** (S): stop the third transcription after
   deliberate empty verdicts (distinct silence error the fallback rethrows);
   drop the unconditional 80ms sleep in prepareForInsertion when the target app
   is already frontmost; prompt-token cache; fold the peak-energy pass into the
   chunk loop.
3. **Whisper-path trigger tightening** (S–M, matters once Whisper re-engages):
   phantom check fires on phantom-SHAPED short text, not every ≤4-word clip;
   near-miss voting skips high-frequency common words (the codex↔"code" trap);
   optionally move voting into the two-phase refine pass (full power, zero felt
   cost). Text heuristics only — the echo defense stays unconditional per the
   Codex ruling.
4. **SpeechAnalyzer streaming during hold** (M; touches capture only as a new
   CONSUMER of existing tap buffers — tap/preroll/format/drain untouched; with
   Yoni live per rule 6): volatile results while speaking, finalize at release.
   Decode cost ~0.9s → ~0.1–0.3s, zero accuracy change (same engine, same final
   results). Apple-path only.
5. **Whisper decode-during-hold** (L, the endgame): LocalAgreement over our own
   buffer + tail-only final decode conditioned on the confirmed prefix (words
   never frozen early ⇒ hybrid erases the ~0.2 WER streaming cost). Requires
   WhisperKit bump to Argmax OSS SDK 1.0 (re-audit the known traps:
   noSpeechThreshold dead config, suppress tokens, prefill interactions).
   Echo/phantom defenses run per tick. No on-device competitor has this.

**Realistic on-device floor: ~0.4–0.8s felt latency** (Argmax ships 0.45s/word
hypothesis latency with our same model on the same silicon). Rejected outright:
distil-large-v3 / small.en as primary (accent risk), speculative decoding
(Argmax measured 1.25x practical — not worth it).
