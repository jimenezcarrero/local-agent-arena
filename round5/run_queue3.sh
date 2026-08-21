#!/bin/bash
# 1) speculative decoding: Qwen3.5-0.8B drafting Ornith-1.0 (quick)
# 2) base Qwen3.5-9B through arena 4, both windows (completes the tuning control)
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
RES="$R5/queue3-results.txt"
COMMON="-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 512 -ub 128 -np 1 --jinja --metrics"
: > "$RES"
stop(){ local p; p=$(pgrep -f "build-novmm/bin/llama-server" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null; sleep 10
        for _ in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
        sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; sleep 2; }

echo "=== 1. draft-simple: Qwen3.5-0.8B (508 MB) drafting Ornith-1.0 ===" >> "$RES"
echo "baseline: Ornith-1.0 solo = 10.3 tok/s" >> "$RES"
for NDRAFT in 4 8; do
  stop
  nohup $BIN -m $M/Ornith-1.0-9B-MTP-IQ3_M.gguf -md $M/Qwen3.5-0.8B-draft-Q4_K_M.gguf \
    --spec-type draft-simple --spec-draft-n-max $NDRAFT -ngld 99 $COMMON -c 32768 \
    --host 127.0.0.1 --port 8080 > "$R5/logs/spec-$NDRAFT.log" 2>&1 &
  ok=""
  for _ in $(seq 1 90); do
    curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q ok && { ok=1; break; }
    grep -qiE "out of memory|error loading|exiting due to|GGML_ASSERT|vocab" "$R5/logs/spec-$NDRAFT.log" && break
    sleep 4
  done
  if [ -n "$ok" ]; then
    R=$(curl -s -m 900 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"x","messages":[{"role":"user","content":"Write a short python function that reverses a linked list, with a docstring."}],"max_tokens":220}' 2>/dev/null \
      | python3 -c "import json,sys;t=json.load(sys.stdin)['timings'];d=t.get('draft_n',0);a=t.get('draft_n_accepted',0);r=(100.0*a/d if d else 0);print('tg %.2f t/s | draft %d/%d accepted (%.0f%%)'%(t['predicted_per_second'],a,d,r))" 2>/dev/null)
    echo "spec n_max=$NDRAFT: *** WORKS *** $R" >> "$RES"
  else
    echo "spec n_max=$NDRAFT: FAIL — $(grep -oiE 'GGML_ASSERT\(.*\)|out of memory|vocab[^\"]*|allocating [0-9.]+ MiB' "$R5/logs/spec-$NDRAFT.log" | tail -1)" >> "$RES"
  fi
done

echo "=== 2. base Qwen3.5-9B — arena 4 both windows ===" >> "$RES"
stop
( cd /home/JetsonOrin/Repositories/pi-arena4 && ./run_crusher.sh qwen9b-a4-32k local32k $BIN -m $M/Qwen3.5-9B-base-IQ4_XS.gguf $COMMON -c 32768 --host 0.0.0.0 --port 8080 ) \
  2>&1 | tee "$R5/logs/qwen9b-a4-32k.log" | grep --line-buffered -E "^RESULT|^TURN" >> "$RES"
stop
( cd /home/JetsonOrin/Repositories/pi-arena4 && ./run_crusher.sh qwen9b-a4-big local $BIN -m $M/Qwen3.5-9B-base-IQ4_XS.gguf $COMMON -c 65536 --host 0.0.0.0 --port 8080 ) \
  2>&1 | tee "$R5/logs/qwen9b-a4-big.log" | grep --line-buffered -E "^RESULT|^TURN" >> "$RES"
stop
echo "=== QUEUE3 COMPLETE ===" >> "$RES"
