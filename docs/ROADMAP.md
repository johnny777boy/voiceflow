# VoiceFlow Roadmap — to sellable Wispr-parity (transcription-first)

Created 2026-08-08. Owner: Yoni. Execution: autonomous sessions following the
workflow in CLAUDE.md (branch → install → Yoni lives on it → triple verification
→ merge). One phase per branch; each phase independently shippable.

Language policy: **English primary, always.** Hebrew planned as SECONDARY later
(Phase H, unscheduled). No other languages considered for now.

## Phase 0 — Merge the current branch (in flight)
`fix/consistent-chat-formatting`: uniform formatting everywhere, phantom-proof
silence (short-clip Apple arbiter), bidirectional verbatim guard, continuation
gaps in AX-blind fields. Status: feature-complete, user-approved live; awaiting
reviewer agents + Codex PASS → merge ritual.

## Phase 1 — Context biasing: the recognizer knows your words (accuracy)
The biggest remaining Wispr edge. Steps:
1. Verify the pinned WhisperKit includes the promptTokens fix (PR #514); bump if not.
2. Feed the user's vocabulary (enabled entries) as Whisper `promptTokens`
   (tokenizer-encoded, filtered below specialTokenBegin) — symmetric with the
   Apple path's contextualStrings (which are inert on SpeechTranscriber — do not
   count on them).
3. AX screen-noun harvesting (Wispr's trick, done locally): read the frontmost
   window's text via Accessibility, extract capitalized/unknown tokens on-device
   (Foundation Models or a simple heuristic), add to the per-dictation prompt.
   Cap prompt length; measure latency cost.
4. WER A/B with and without biasing on the user's voice.
Exit criteria: proper nouns/jargon from screen + vocabulary transcribe correctly;
no latency regression > 200ms.

## Phase 2 — Prove it: measurement & visibility (sellability)
1. Raw-mode WER benchmark on the user's voice (protocol exists:
   docs/ACCURACY_BENCHMARK.md; Raw mode is now truly verbatim). Record the
   number; optionally A/B full large-v3 (`whisperModelVariant` override).
2. Show rawText vs cleanText in the history UI (diagnostic + trust).
3. Track a local "zero-edit rate" style metric (did the user edit after insert?
   start simple: none).
Exit criteria: a defensible accuracy number + visible raw/clean history.

## Phase 3 — Latency: sub-1s feel (robustness perception)
From the parity plan §3.3, in order: warm the LLM session at record-start;
tier/skip LLM cleanup for short utterances; move the 0.18s drain off-main;
two-phase delivery (insert rule-cleaned instantly, LLM-polish in place) — gated
behind a setting, needs live testing. Whisper streaming/chunked decode only if
still needed after the above.
Exit criteria: release→text under ~1.5s median on the user's machine (from
current 2–4s), measured by a release-to-insert metric added first.

## Phase 4 — Self-learning dictionary (retention/delight)
Watch post-insertion edits via AX (short window after insert, privacy-safe,
on-device): when the user corrects an inserted word the same way 2–3 times,
propose (or silently add) a vocabulary entry. Feeds Phase 1's biasing.
Exit criteria: a corrected word starts transcribing correctly within 3 uses.

## Phase 5 — Word-level dual-engine rescoring (accuracy tail)
Extend the silence-arbiter into agreement rescoring: run both engines on the
same buffer when confidence is low or vocabulary tokens are suspected; let the
on-device LLM arbitrate ONLY between the two engines' words (never invent).
Exit criteria: measurable WER drop on the hard-sentence set; zero invented words.

## Phase H — Hebrew as secondary language (unscheduled, after 1–5)
English remains primary. Whisper large-v3 already supports Hebrew; scope:
language toggle UI, per-language decode options, RTL insertion correctness,
cleanup rules for Hebrew, benchmark set. Do NOT start before Phases 1–3 ship.

## Parking lot (from reviews/research; grab when adjacent)
- Deferred review findings: BACKLOG.md §1c (sharesStem cap, variant-cache check,
  hide Whisper toggle pre-macOS 26, level micro-race, .incomplete cleanup, etc.)
- Calmer "Didn't catch anything" pill message for vetoed silence (replaces
  generic "Try again").
- Mic device picker (settings field exists, dead code today) + low-rate
  Bluetooth warning surfaced in UI.
- Preroll trim 0.8s→~0.3s (audio path — live-mic session only).
- Noise suppression experiment (audio path — live-mic session only).
- Sellability infra (not transcription): notarized distribution, updater,
  onboarding/permissions walkthrough, website + zero-edit-rate claims.
  (Product-research agent findings to be folded in here.)
