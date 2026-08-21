#!/bin/bash
# Fill the "not run" gaps with the current stack + learnings.
#  1) LFM2.5 Q8_0 arena 1 - one retry on the new stack (new llama.cpp + pi 0.80)
#  2) Bonsai-27B arena 2  - never run; feasible at 3.53 GB
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
RES="$R5/gaps-results.txt"
COMMON="-ngl 99 -fa on -np 1 --jinja --metrics"
: > "$RES"
stop(){ local p; p=$(pgrep -f "build-novmm/bin/llama-server" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null; sleep 10
        for _ in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
        sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; sleep 2; }

echo "=== 1. LFM2.5 Q8_0 — arena 1 retry on current stack ===" >> "$RES"
echo "(previously failed 4x on the old stack: Q4_K_M x2, Q8_0, Q4+vendor sampling)" >> "$RES"
stop
( cd /home/JetsonOrin/Repositories/pi-shootout && ./run_one.sh lfm-q8-retry $BIN \
  -m $M/LFM2.5-2.6B-Q8_0.gguf $COMMON -ctk q4_0 -ctv q4_0 -c 65536 -b 512 -ub 128 \
  --temp 0.1 --top-k 50 --repeat-penalty 1.1 --host 0.0.0.0 --port 8080 ) \
  2>&1 | tee "$R5/logs/lfm-q8-retry.log" | grep --line-buffered "^RESULT" >> "$RES"

echo "=== 2. Bonsai-27B Q1_0 — arena 2 (never run; 6 tok/s so expect ~30 min) ===" >> "$RES"
stop
( cd /home/JetsonOrin/Repositories/pi-arena2 && ./run_one.sh bonsai-a2 $BIN \
  -m $M/Bonsai-27B-Q1_0.gguf $COMMON -ctk q8_0 -ctv q8_0 -c 32768 -b 512 -ub 128 \
  --host 0.0.0.0 --port 8080 ) \
  2>&1 | tee "$R5/logs/bonsai-a2.log" | grep --line-buffered "^RESULT" >> "$RES"
stop
echo "=== GAPS COMPLETE ===" >> "$RES"
