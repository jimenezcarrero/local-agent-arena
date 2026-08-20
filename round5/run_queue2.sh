#!/bin/bash
# 1) MTP 2-layer draft test (quick)   2) base Qwen3.5-9B marathon (slow)
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
RES="$R5/queue2-results.txt"
COMMON="-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 512 -ub 128 -np 1 --jinja --metrics"
: > "$RES"
stop(){ local p; p=$(pgrep -f "build-novmm/bin/llama-server" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null; sleep 10
        for _ in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
        sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; sleep 2; }

echo "=== 1. MTP 2-layer head draft (1634 MB) + Ornith-1.0 target ===" >> "$RES"
for CTX in 8192 4096; do
  stop
  nohup $BIN -m $M/Ornith-1.0-9B-MTP-IQ3_M.gguf -md $M/mtp-ornith-1.0-head2.gguf \
    --spec-type draft-mtp -ngld 99 $COMMON -c $CTX --host 127.0.0.1 --port 8080 \
    > "$R5/logs/mtp2-$CTX.log" 2>&1 &
  ok=""
  for _ in $(seq 1 90); do
    curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q ok && { ok=1; break; }
    grep -qiE "out of memory|error loading|exiting due to|GGML_ASSERT|failed to load" "$R5/logs/mtp2-$CTX.log" && break
    sleep 4
  done
  if [ -n "$ok" ]; then
    R=$(curl -s -m 900 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"x","messages":[{"role":"user","content":"Count 1 to 40, comma separated."}],"max_tokens":150}' 2>/dev/null \
      | python3 -c "import json,sys;t=json.load(sys.stdin)['timings'];print('tg %.2f t/s | draft %d/%d accepted'%(t['predicted_per_second'],t.get('draft_n_accepted',0),t.get('draft_n',0)))" 2>/dev/null)
    echo "MTP2 @${CTX}: *** LOADED *** $R   (Ornith-1.0 solo = 10.3 t/s)" >> "$RES"
    stop; break
  else
    echo "MTP2 @${CTX}: FAIL — $(grep -oiE 'GGML_ASSERT\(.*\)|out of memory|allocating [0-9.]+ MiB' "$R5/logs/mtp2-$CTX.log" | tail -1)" >> "$RES"
  fi
done

echo "=== 2. base Qwen3.5-9B IQ4_XS — 11-turn marathon (does tuning matter in sessions?) ===" >> "$RES"
stop
( cd /home/JetsonOrin/Repositories/pi-arena3 && ./run_multiturn.sh qwen9b-a3 $BIN -m $M/Qwen3.5-9B-base-IQ4_XS.gguf $COMMON -c 32768 --host 0.0.0.0 --port 8080 ) \
  2>&1 | tee "$R5/logs/qwen9b-a3.log" | grep --line-buffered -E "^RESULT|^TURN" >> "$RES"
stop
echo "=== QUEUE2 COMPLETE ===" >> "$RES"
