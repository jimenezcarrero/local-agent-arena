#!/bin/bash
# Qwen3.8-27B ceiling test. Finds the largest quant that runs and the most GPU
# layers it can hold, stepping -ngl down until it loads. Writes machine-readable
# progress to STATUS so `q38status` can report step X of Y, phase, and errors.
set -u
LLAMA=/home/JetsonOrin/.local/bin/llama
MODELS=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
STATUS="$R5/qwen38-status.env"
OUT="$R5/qwen38-results.txt"
LOGS="$R5/logs"
MODE="${1:-partial}"          # partial | full
CTX="${2:-4096}"
FA="${3:-on}"                 # on | off  (Qwen3.8-27B needs off on sm_87/b10217)
KV="${4:-q4_0}"               # q4_0 | f16

# label:file:expected_bytes   (biggest -> smallest, as requested)
SPECS=(
  "IQ2_XXS:Qwen3.8-27B-UD-IQ2_XXS.gguf:7266070528"
  "IQ1_M:Qwen3.8-27B-UD-IQ1_M.gguf:6729166848"
  "IQ1_S:Qwen3.8-27B-UD-IQ1_S.gguf:6192222208"
)
[ "$MODE" = "full" ] && NGLS=(99) || NGLS=(99 56 48 40 32 24 16 8 0)
TOTAL=${#SPECS[@]}

w() { # write a key to the status file
  local k="$1" v="$2"
  grep -v "^$k=" "$STATUS" 2>/dev/null > "$STATUS.tmp" || true
  echo "$k=$v" >> "$STATUS.tmp"; mv "$STATUS.tmp" "$STATUS"
}

: > "$STATUS"
w STATE running; w MODE "$MODE"; w TOTAL_STEPS "$TOTAL"; w STEP 0
w STEP_LABEL "-"; w PHASE starting; w ERRORS 0; w PID $$
w RUN_STARTED "$(date +%s)"; w STEP_STARTED "$(date +%s)"
echo "=== QWEN3.8-27B $MODE-offload run (fa=$FA kv=$KV ctx=$CTX) $(date) ===" >> "$OUT"
echo "free at start: $(free -m | awk 'NR==2{print $7}') MB" >> "$OUT"

err() { w ERRORS "$(( $(grep -oP '(?<=^ERRORS=)\d+' "$STATUS" 2>/dev/null || echo 0) + 1 ))"; }

stop() {
  local p; p=$(pgrep -f "^${LLAMA} serve" 2>/dev/null)
  [ -n "$p" ] && kill $p 2>/dev/null
  sleep 8
  for _ in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
}
trap 'stop; w STATE aborted; exit 130' INT TERM

step=0
for spec in "${SPECS[@]}"; do
  IFS=: read -r label file want <<< "$spec"
  step=$((step+1))
  w STEP "$step"; w STEP_LABEL "$label"; w STEP_STARTED "$(date +%s)"

  # wait for the download of this file to finish (if still running)
  w PHASE "waiting-for-download"
  for _ in $(seq 1 720); do
    [ "$(stat -c%s "$MODELS/$file" 2>/dev/null || echo 0)" -ge "$want" ] && break
    sleep 10
  done
  if [ "$(stat -c%s "$MODELS/$file" 2>/dev/null || echo 0)" -lt "$want" ]; then
    echo "$label: SKIPPED (download incomplete)" >> "$OUT"; err; continue
  fi

  loaded=""
  for ngl in "${NGLS[@]}"; do
    w PHASE "loading ngl=$ngl"
    stop
    if [ "$KV" = "f16" ]; then KVARGS=""; else KVARGS="-ctk $KV -ctv $KV"; fi
    nohup $LLAMA serve -m "$MODELS/$file" -ngl "$ngl" -fa "$FA" $KVARGS \
      -c "$CTX" -np 1 --jinja --metrics --host 127.0.0.1 --port 8080 \
      > "$LOGS/q38-${label}-ngl${ngl}.log" 2>&1 &
    ok=""
    for _ in $(seq 1 150); do
      curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q ok && { ok=1; break; }
      grep -qiE "out of memory|error loading model|failed to allocate|exiting due to" \
        "$LOGS/q38-${label}-ngl${ngl}.log" && break
      sleep 4
    done
    if [ -n "$ok" ]; then loaded="$ngl"; break; fi
    need=$(grep -oE "allocating [0-9.]+ MiB" "$LOGS/q38-${label}-ngl${ngl}.log" | tail -1)
    echo "$label ngl=$ngl: FAIL ${need:-}" >> "$OUT"
    [ "$MODE" = "full" ] && break
  done

  if [ -z "$loaded" ]; then
    echo "$label: NO CONFIG LOADED" >> "$OUT"; err; stop; continue
  fi

  w PHASE "measuring ngl=$loaded"
  sp=$(curl -s -m 1800 http://127.0.0.1:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"x","messages":[{"role":"user","content":"Write one paragraph about edge computing."}],"max_tokens":100}' \
    | python3 -c "import json,sys
try:
    t=json.load(sys.stdin)['timings']
    print(f\"pp {t['prompt_per_second']:.1f} t/s | tg {t['predicted_per_second']:.2f} t/s\")
except Exception:
    print('speed-probe-failed')" 2>/dev/null)
  [ "$sp" = "speed-probe-failed" ] && err
  echo "$label: LOADED at ngl=$loaded | $sp | free after: $(free -m | awk 'NR==2{print $7}') MB" >> "$OUT"
  w LAST_RESULT "$label ngl=$loaded $sp"
  stop
done

w PHASE done; w STATE complete; w FINISHED "$(date +%s)"
echo "=== RUN COMPLETE $(date) ===" >> "$OUT"
