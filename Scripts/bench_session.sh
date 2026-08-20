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
#   Scripts/bench_session.sh ready     wait until Whisper has finished loading
#   Scripts/bench_session.sh status    how many captures are in the corpus
#   Scripts/bench_session.sh stop      STOP retaining audio (do not forget this)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$HOME/Library/Application Support/VoiceFlow/Benchmark"
OUT="$HOME/Library/Application Support/VoiceFlow/Benchmark-results"
REF="$ROOT/docs/wer-reference-long.txt"
ENTITIES="$ROOT/docs/wer-entities.txt"
TURBO="openai_whisper-large-v3-v20240930_turbo"
LARGE="openai_whisper-large-v3"           # 32 decoder layers = the REAL full model
mkdir -p "$OUT"

case "${1:-help}" in
  start)
    defaults write com.voiceflow.dictation benchmarkRetainCaptures -bool YES
    rm -rf "$CORPUS"; mkdir -p "$CORPUS"
    echo "Benchmark mode ON, corpus cleared."
    echo
    echo "  1. QUIT AND REOPEN VoiceFlow (the flag is read at launch)."
    echo "  2. Scripts/bench_session.sh ready     ← WAIT for Whisper to load"
    echo "  3. Scripts/bench_session.sh prompts   ← read each line as ONE dictation"
    echo "  4. Scripts/bench_session.sh models    ← get the answer"
    echo
    echo "You can stop and continue later — the corpus keeps accumulating until"
    echo "you run 'start' again (which clears it)."
    echo
    echo "Audio stays on this Mac — but until you stop it, EVERY dictation is"
    echo "kept on disk, including your real work. When you are done:"
    echo "  Scripts/bench_session.sh stop"
    ;;
  ready)
    # Captures are archived ONLY on the Whisper route. After a relaunch the model
    # takes tens of seconds to load, and every line read during that window goes
    # to the Apple engine, inserts text normally (so it LOOKS fine) and is never
    // archived — leaving the corpus starting at spoken line N+1 while the
    # reference starts at line 1. Every pair misaligned, both models scoring
    # 85-100% WER, and the verdict reads "no significant difference".
    echo "Waiting for the Whisper engine to finish loading…"
    for i in $(seq 1 60); do
      if log show --last 10m --predicate 'process == "VoiceFlow"' --info 2>/dev/null \
         | grep -q "Whisper ready"; then
        echo "Whisper is ready. Now: Scripts/bench_session.sh prompts"; exit 0
      fi
      sleep 5
    done
    echo "Could not confirm Whisper is ready after 5 minutes."
    echo "Open VoiceFlow ▸ Settings and check High Accuracy shows Ready before reading."
    exit 1
    ;;
  prompts)
    COUNT="$(ls "$CORPUS" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$COUNT" -eq 0 ]]; then
      echo "NOTE: the corpus is empty. If you have not run 'ready' since relaunching,"
      echo "do that FIRST — lines read before Whisper finishes loading are not saved,"
      echo "and that silently misaligns every measurement."
      echo
    fi
    echo "Read each line aloud as ONE dictation, in order, at your normal pace."
    echo "Speak the way you actually speak — do not over-enunciate, that would"
    echo "measure a voice you never use."
    echo
    nl -ba "$REF"
    echo
    echo "Then: Scripts/bench_session.sh models"
    ;;
  stop)
    defaults write com.voiceflow.dictation benchmarkRetainCaptures -bool NO
    COUNT="$(ls "$CORPUS" 2>/dev/null | wc -l | tr -d ' ')"
    echo "Benchmark mode OFF. Quit and reopen VoiceFlow to stop retaining audio."
    echo "$COUNT recordings are still in $CORPUS"
    echo "Delete them when you are done:  rm -rf \"$CORPUS\""
    ;;
  status)
    COUNT="$(ls "$CORPUS" 2>/dev/null | wc -l | tr -d ' ')"
    EXPECTED="$(grep -c . "$REF")"
    echo "$COUNT captures in the corpus (the read script has $EXPECTED lines)."
    [[ "$COUNT" -lt "$EXPECTED" ]] && echo "Keep going — or use 'models' anyway to score what you have."
    ;;
  models)
    python3 "$ROOT/Scripts/wer_compare.py" --self-test || exit 1
    rm -f "$OUT"/hyp-*.txt      # never score a stale file from a previous run
    echo "Decoding your audio under BOTH models — same files, no re-reading."
    swift run --package-path "$ROOT" VoiceFlowBench --audio "$CORPUS" \
      --model "$TURBO" --out "$OUT/hyp-turbo.txt"
    swift run --package-path "$ROOT" VoiceFlowBench --audio "$CORPUS" \
      --model "$LARGE" --out "$OUT/hyp-large.txt"
    echo
    # If the two runs produced byte-identical text, the SAME model ran twice.
    # That reads as a clean "no difference" and is indistinguishable from a real
    # tie — the exact trap that has caught this project three times.
    if cmp -s "$OUT/hyp-turbo.txt" "$OUT/hyp-large.txt"; then
      echo "FATAL: the two runs produced IDENTICAL text — the same model ran twice."
      echo "Check the 'decoder layers' line printed by each run: 4 = turbo, 32 = full."
      exit 1
    fi
    python3 "$ROOT/Scripts/wer_compare.py" "$REF" "$OUT/hyp-turbo.txt" "$OUT/hyp-large.txt" \
      --labels "turbo (current)","large-v3 (full)" --entities "$ENTITIES"
    echo
    echo "Done measuring? Stop retaining audio:  Scripts/bench_session.sh stop"
    ;;
  bias)
    TERMS=()
    while IFS= read -r line; do [[ -n "$line" ]] && TERMS+=("$line"); done < "$ENTITIES"
    python3 "$ROOT/Scripts/wer_compare.py" --self-test || exit 1
    rm -f "$OUT"/hyp-nobias.txt "$OUT"/hyp-bias.txt
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
