#!/bin/bash
# Queued work, cheapest first. Waits for the Ornith-1.0 re-baseline to finish.
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
RES="$R5/queue-results.txt"
COMMON="-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 512 -ub 128 -np 1 --jinja --metrics"

while pgrep -f rebaseline_ornith10 >/dev/null; do sleep 60; done
: > "$RES"
stop(){ local p; p=$(pgrep -f "build-novmm/bin/llama-server" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null; sleep 10
        for _ in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
        sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; sleep 2; }

# ---- 1. MTP head-draft test (cheapest) ----
echo "=== 1. MTP head-only draft test ===" >> "$RES"
for CTX in 8192 4096; do
  stop
  nohup $BIN -m $M/Ornith-1.0-9B-MTP-IQ3_M.gguf -md $M/mtp-ornith-1.0-head.gguf \
    --spec-type draft-mtp -ngld 99 $COMMON -c $CTX --host 127.0.0.1 --port 8080 \
    > "$R5/logs/mtp-test-$CTX.log" 2>&1 &
  ok=""
  for _ in $(seq 1 80); do
    curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q ok && { ok=1; break; }
    grep -qiE "out of memory|error loading|exiting due to|failed" "$R5/logs/mtp-test-$CTX.log" && break
    sleep 4
  done
  if [ -n "$ok" ]; then
    R=$(curl -s -m 600 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"x","messages":[{"role":"user","content":"Count 1 to 40."}],"max_tokens":150}' 2>/dev/null \
      | python3 -c "import json,sys;t=json.load(sys.stdin)['timings'];d=t.get('draft_n',0);a=t.get('draft_n_accepted',0);print('tg %.2f t/s | draft %d/%d accepted'%(t['predicted_per_second'],a,d))" 2>/dev/null)
    echo "MTP draft @${CTX}: *** ACCEPTED *** $R   (Ornith-1.0 solo baseline: 10.3 t/s)" >> "$RES"
    stop; break
  else
    echo "MTP draft @${CTX}: FAIL $(grep -oiE 'out of memory|unknown model architecture|allocating [0-9.]+ MiB|failed to load' "$R5/logs/mtp-test-$CTX.log" | tail -1)" >> "$RES"
  fi
done

# ---- 2. base Qwen3.5-9B: arenas 1 and 2 (tuning control vs Ornith-1.5) ----
echo "=== 2. base Qwen3.5-9B IQ4_XS (control for agentic tuning) ===" >> "$RES"
stop
( cd /home/JetsonOrin/Repositories/pi-shootout && ./run_one.sh qwen9b-a1 $BIN -m $M/Qwen3.5-9B-base-IQ4_XS.gguf $COMMON -c 32768 --host 0.0.0.0 --port 8080 ) \
  2>&1 | tee "$R5/logs/qwen9b-a1.log" | grep --line-buffered "^RESULT" >> "$RES"
stop
( cd /home/JetsonOrin/Repositories/pi-arena2 && ./run_one.sh qwen9b-a2 $BIN -m $M/Qwen3.5-9B-base-IQ4_XS.gguf $COMMON -c 32768 --host 0.0.0.0 --port 8080 ) \
  2>&1 | tee "$R5/logs/qwen9b-a2.log" | grep --line-buffered "^RESULT" >> "$RES"

# ---- 3. Ornith-1.5 marathon re-run (slowest) ----
echo "=== 3. Ornith-1.5 IQ4_XS marathon re-run ===" >> "$RES"
stop
( cd /home/JetsonOrin/Repositories/pi-arena3 && ./run_multiturn.sh o15-a3c $BIN -m $M/Ornith-1.5-9B-IQ4_XS.gguf $COMMON -c 65536 --host 0.0.0.0 --port 8080 ) \
  2>&1 | tee "$R5/logs/o15-a3c.log" | grep --line-buffered -E "^RESULT|^TURN" >> "$RES"

stop
echo "=== QUEUE COMPLETE ===" >> "$RES"
