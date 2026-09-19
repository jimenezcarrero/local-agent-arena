#!/bin/bash
# Retry speculative decoding with a QUANTIZED draft KV cache (-ctkd/-ctvd q4_0).
# The draft's f16 KV was the 384 MiB allocation that OOM'd.
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
RES="$R5/queue4-results.txt"
COMMON="-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 512 -ub 128 -np 1 --jinja --metrics"
while pgrep -f run_queue3.sh >/dev/null; do sleep 60; done
: > "$RES"
stop(){ local p; p=$(pgrep -f "build-novmm/bin/llama-server" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null; sleep 10
        for _ in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
        sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; sleep 2; }

echo "=== speculative decoding, quantized draft KV (baseline Ornith-1.0 solo = 10.3 tok/s) ===" >> "$RES"
for CFG in "32768 4" "32768 8" "16384 4"; do
  set -- $CFG; CTX=$1; ND=$2
  stop
  nohup $BIN -m $M/Ornith-1.0-9B-MTP-IQ3_M.gguf -md $M/Qwen3.5-0.8B-draft-Q4_K_M.gguf \
    --spec-type draft-simple --spec-draft-n-max $ND -ngld 99 \
    -ctkd q4_0 -ctvd q4_0 $COMMON -c $CTX \
    --host 127.0.0.1 --port 8080 > "$R5/logs/spec2-$CTX-$ND.log" 2>&1 &
  ok=""
  for _ in $(seq 1 90); do
    curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q ok && { ok=1; break; }
    grep -qiE "out of memory|error loading|exiting due to|GGML_ASSERT" "$R5/logs/spec2-$CTX-$ND.log" && break
    sleep 4
  done
  if [ -n "$ok" ]; then
    R=$(curl -s -m 900 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"x","messages":[{"role":"user","content":"Write a short python function that reverses a linked list, with a docstring."}],"max_tokens":220}' 2>/dev/null \
      | python3 -c "import json,sys;t=json.load(sys.stdin)['timings'];d=t.get('draft_n',0);a=t.get('draft_n_accepted',0);r=(100.0*a/d if d else 0);print('tg %.2f t/s | draft %d/%d accepted (%.0f%%)'%(t['predicted_per_second'],a,d,r))" 2>/dev/null)
    echo "ctx=$CTX n_max=$ND: *** WORKS *** $R" >> "$RES"
  else
    echo "ctx=$CTX n_max=$ND: FAIL — $(grep -oiE 'allocating [0-9.]+ MiB|out of memory' "$R5/logs/spec2-$CTX-$ND.log" | tail -1)" >> "$RES"
  fi
done
stop
echo "=== QUEUE4 COMPLETE ===" >> "$RES"
