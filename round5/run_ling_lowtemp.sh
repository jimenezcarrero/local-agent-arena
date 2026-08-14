#!/bin/bash
# Ling arena-3 A/B: same model/window, temp 0.3 instead of the card's temp 1.0.
# Waits for the arena-4 phase to finish so the two never share the GPU.
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp-bailing/build/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models/Ling-3.0-tiny-Q3_K_M.gguf
R5=/home/JetsonOrin/Repositories/round5-newmodels
RESULTS="$R5/results.txt"

until grep -q "LING PHASE 2 COMPLETE" "$RESULTS" 2>/dev/null; do sleep 60; done

stop() {
  local p
  p=$(pgrep -f "llama.cpp-bailing/build/bin/llama-server" 2>/dev/null)
  [ -n "$p" ] && kill $p 2>/dev/null
  sleep 6
  for _ in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
}

stop; echo "[$(date +%H:%M:%S)] START a3-ling-t03 (temp 0.3 A/B)" >> "$RESULTS"
( cd /home/JetsonOrin/Repositories/pi-arena3 && ./run_multiturn.sh a3-ling-t03 $BIN \
  -m $M -ngl 99 -fa on -ctk q4_0 -ctv q4_0 -np 1 --jinja --metrics \
  --temp 0.3 --top-p 0.95 --top-k 20 -c 131072 --host 0.0.0.0 --port 8080 ) \
  2>&1 | tee "$R5/logs/a3-ling-t03.log" | grep --line-buffered -E "^RESULT|^TURN" >> "$RESULTS"

stop
echo "LING LOWTEMP AB COMPLETE" >> "$RESULTS"
