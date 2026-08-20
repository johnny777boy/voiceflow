# How this class of problem is actually solved (research, 2026-08-19)

Question Yoni asked: *"what is the correct way to fix this issue, professional
way?"* — the issue being that the app keeps mis-hearing the same words, and the
learning system never learns them.

The answer is a three-layer architecture, and **we are currently missing the
most important layer for a reason that was fixed upstream three weeks ago.**

---

## Layer 1 — Fix it at the RECOGNIZER (contextual biasing)

The professional fix is not to patch the text afterwards. It is to tell the
recognizer, before it decodes, which rare words are likely — so the word is
never wrong in the first place. For Whisper this is the `initial_prompt` /
`promptTokens` channel: prompt text is prepended to the decoder input and biases
it toward preferred spellings and proper nouns, while still reconciling against
the acoustics.

Practical constraints (they shape the design, not just the code):
- only the **last 224 tokens** of the prompt are consumed;
- **later tokens carry more weight**, so the highest-value rare words go last;
- the prompt should be a compact natural sentence, not a word dump.

### Why ours is off, and why that is now fixable

Our note said "promptTokens makes WhisperKit 0.18 emit zero characters — ROOT
CAUSE STILL OPEN". **It is not our bug and it is no longer open.** It is
WhisperKit issue #372, and PR #514 (merged 2026-07-30) explains it exactly:

> the decode loop honored predictions made while force-feeding the initial
> prompt, allowing an end-of-text token sampled during this "prefill" phase to
> prematurely terminate the segment.

That is precisely the symptom we measured — every clip decoding to nothing. The
fix gates EOT while the prompt is still being forced, re-anchors the confidence
check to the first genuinely decoded token, and skips empty prompts. It also
fixes an out-of-bounds crash with `suppressTokens: [-1]` — and we build a
suppress-token list, so that one is relevant to us too.

**We are pinned to WhisperKit 0.18.0 (2026-04-01). The fix ships in v1.1.0
(2026-08-06).** Upgrading is the single highest-leverage accuracy action
available, and it unblocks the headline feature that has been dormant since
Phase 1.

### The Apple engine cannot be biased at all

Worth knowing before anyone tries: **SpeechAnalyzer (macOS 26) has no custom
vocabulary API.** The old `SFSpeechRecognizer` had `contextualStrings`, and the
new framework dropped it — migrating to SpeechAnalyzer is a documented accuracy
*regression* for exactly this feature. So on the Apple fallback path, biasing is
not available at any price; `SFSpeechLanguageModel` / `SFCustomLanguageModelData`
only serve the older API. This is an argument for Whisper being the primary
engine, not a bug to chase.

---

## Layer 2 — Correct it AFTER transcription (works on every engine)

This is the universal fallback, and the whole category relies on it. A survey of
19 speech-to-text integrations found that **10 silently drop custom dictionary
terms** because their engines expose no biasing hook — WhisperKit and Apple
SpeechAnalyzer are both on that list. Their conclusion: post-transcription
corrections "work everywhere and are unaffected".

**Where ours falls short.** `VocabularyReplacer` is exact-phrase matching
(regex, case-insensitive, word-boundary). It only fires on a mishearing the user
predicted in advance — which is why Yoni's vocabulary already contains hand-
enumerated variants: `codices`, `codecs`, `codeex` → Codex; `git hop`, `get hub`
→ GitHub; `clod code`, `closed code` → Claude Code. **Making the user enumerate
every way a word can be misheard is the design flaw.** It also explains today's
live failures: `chat GPT` had no entry, and `interven results` never could have
one.

The professional version matches by **sound, not spelling**: a phonetic key
(Double Metaphone / Soundex) plus a bounded edit-distance check, so ONE entry —
"Codex" — catches every mishearing that sounds like it, including ones nobody
predicted. Constrained to the user's own vocabulary list, this cannot invent
words, which keeps it inside the verbatim rule.

---

## Layer 3 — The LEARNING loop (how entries get added)

Measured today: in Claude, where **40 of his 42 dictations happen, the
correction watcher has observed exactly ZERO corrections**; in Chrome it caught
2 of 2. The current design requires a fix within 6 seconds, in an
Accessibility-readable field, in the same app, before the message is sent, the
same way 3 times. In a chat app that chain never completes.

Sniffing text fields on a timer is the wrong foundation — it is fragile by
construction and permanently blind in Electron. The professional shape is:

1. **One explicit, cheap correction path** — the deliberate report
   (`Scripts/report_bad.py`, built today) is this, and it works everywhere.
2. **Passive signals as CANDIDATES only, never as truth.** We now have one that
   needs no Accessibility and no timing window: **the guard's refusals.** When
   the model repeatedly proposes a word the guard blocks — `ChatGPT` today —
   that is a vocabulary candidate the app discovered by itself.
3. **Propose, never mutate.** Keep this. It is already right.

---

## Recommended order (highest leverage first)

1. **Measure.** `Scripts/wer_session.sh` — 3 minutes, Yoni's voice. Nothing
   below can be verified without a baseline, and the standing rule requires a
   WER A/B for any accuracy change.
2. **Upgrade WhisperKit 0.18.0 → v1.1.0 and re-enable biasing** behind the
   existing `whisperPromptBiasingEnabled` switch, then WER A/B it. Major version
   jump, so expect API changes; the dev switch already exists to ship it off
   until proven.
3. **Phonetic vocabulary matching** (Layer 2) — removes the "predict every
   mishearing" burden. Independent of the upgrade, safe, testable offline.
4. **Learning-loop redesign** (Layer 3) — feed candidates from guard refusals
   and explicit reports; retire the 6-second AX watcher as the primary path.

## Sources

- WhisperKit issue #372 — https://github.com/argmaxinc/WhisperKit/issues/372
- WhisperKit PR #514 (the fix) — https://github.com/argmaxinc/WhisperKit/pull/514
- WhisperKit releases (v1.1.0, 2026-08-06) — https://github.com/argmaxinc/WhisperKit/releases
- Contextual biasing for custom vocabulary without fine-tuning Whisper — https://arxiv.org/pdf/2410.18363
- Improving rare-word recognition of Whisper zero-shot — https://arxiv.org/pdf/2502.11572
- LLM-driven context generation for ASR (prompt construction, 224-token limit) — https://arxiv.org/html/2602.18966v1
- Survey: dictionary terms silently dropped by 10 of 19 STT engines — https://github.com/TypeWhisper/typewhisper-mac/issues/294
- Apple SpeechAnalyzer lacks custom vocabulary — https://www.argmaxinc.com/blog/apple-and-argmax
- SFSpeechRecognitionRequest.contextualStrings — https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings
- SFCustomLanguageModelData — https://developer.apple.com/documentation/speech/sfcustomlanguagemodeldata
