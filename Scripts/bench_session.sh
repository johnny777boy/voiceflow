#!/usr/bin/env bash
# Turn one dictation session into an answer about accuracy.
#
# The old protocol was "read the script, switch model, read it again". That
# measures the READING as much as the model — and on a 136-word reference a
# single error moves WER by 0.74, far more than the ~1 point the model question
# turns on. So this records your audio ONCE and decodes the same files under
# every configuration, which makes each utterance a matched pair.
#
#   Scripts/bench_session.sh start     arm capture retention, clear the corpus
#   Scripts/bench_session.sh prompts   the lines to read, one dictation each
#   Scripts/bench_session.sh models    turbo vs full large-v3 on YOUR audio
#   Scripts/bench_session.sh bias      context biasing off vs on
#   Scripts/bench_session.sh status    how many captures are in the corpus
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$HOME/Library/Application Support/VoiceFlow/Benchmark"
OUT="$HOME/Library/Application Support/VoiceFlow/Benchmark-results"
REF="$ROOT/docs/wer-reference-long.txt"
ENTITIES="$ROOT/docs/wer-entities.txt"
TURBO="openai_whisper-large-v3-v20240930_turbo"
LARGE="openai_whisper-large-v3-v20240930"
mkdir -p "$OUT"

case "${1:-help}" in
  start)
    defaults write com.voiceflow.dictation benchmarkRetainCaptures -bool YES
    rm -rf "$CORPUS"; mkdir -p "$CORPUS"
    echo "Benchmark mode ON, corpus cleared."
    echo
    echo "  1. QUIT AND REOPEN VoiceFlow (the flag is read at launch)."
    echo "  2. Scripts/bench_session.sh prompts   ← read each line as ONE dictation"
    echo "  3. Scripts/bench_session.sh models    ← get the answer"
    echo
    echo "Audio stays on this Mac. Turn it off again with:"
    echo "  defaults write com.voiceflow.dictation benchmarkRetainCaptures -bool NO"
    ;;
  prompts)
    echo "Read each line aloud as ONE dictation, in order, at your normal pace."
    echo "Speak the way you actually speak — do not over-enunciate, that would"
    echo "measure a voice you never use."
    echo
    nl -ba "$REF"
    echo
    echo "Then: Scripts/bench_session.sh models"
    ;;
  status)
    COUNT="$(ls "$CORPUS" 2>/dev/null | wc -l | tr -d ' ')"
    EXPECTED="$(grep -c . "$REF")"
    echo "$COUNT captures in the corpus (the read script has $EXPECTED lines)."
    [[ "$COUNT" -lt "$EXPECTED" ]] && echo "Keep going — or use 'models' anyway to score what you have."
    ;;
  models)
    echo "Decoding your audio under BOTH models — same files, no re-reading."
    swift run --package-path "$ROOT" VoiceFlowBench --audio "$CORPUS" \
      --model "$TURBO" --out "$OUT/hyp-turbo.txt"
    swift run --package-path "$ROOT" VoiceFlowBench --audio "$CORPUS" \
      --model "$LARGE" --out "$OUT/hyp-large.txt"
    echo
    python3 "$ROOT/Scripts/wer_compare.py" "$REF" "$OUT/hyp-turbo.txt" "$OUT/hyp-large.txt" \
      --labels "turbo (current)","large-v3 (full)" --entities "$ENTITIES"
    ;;
  bias)
    TERMS=()
    while IFS= read -r line; do [[ -n "$line" ]] && TERMS+=("$line"); done < "$ENTITIES"
    echo "Decoding your audio with context biasing OFF, then ON — same files."
    swift run --package-path "$ROOT" VoiceFlowBench --audio "$CORPUS" \
      --out "$OUT/hyp-nobias.txt"
    swift run --package-path "$ROOT" VoiceFlowBench --audio "$CORPUS" \
      --bias "${TERMS[@]}" --out "$OUT/hyp-bias.txt" -whisperPromptBiasingEnabled YES
    echo
    python3 "$ROOT/Scripts/wer_compare.py" "$REF" "$OUT/hyp-nobias.txt" "$OUT/hyp-bias.txt" \
      --labels "no biasing","biasing on" --entities "$ENTITIES"
    echo
    echo "Watch ENTITY RECALL, not overall WER: biasing is supposed to move the"
    echo "names and jargon. If overall WER got WORSE, the prompt is contaminating"
    echo "style and it must not ship."
    ;;
  *)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
