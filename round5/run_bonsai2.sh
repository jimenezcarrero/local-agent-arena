#!/bin/bash
# Bonsai-27B arena 2 retry: q8 KV at 32K needed 1088 MiB and OOM'd.
# q4 KV quarters that; step the window down until it fits.
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
RES="$R5/bonsai-retry.txt"
while pgrep -f "run_lfm2.sh|run_qwen9b_smaller.sh|run_qwen9b_consistent.sh" >/dev/null; do sleep 60; done
: > "$RES"
stop(){ local p; p=$(pgrep -f "build-novmm/bin/llama-server" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null; sleep 10
        for _ in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
        sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; sleep 2; }
echo "=== Bonsai-27B Q1_0 arena 2 (q8 KV @32K OOM'd on 1088 MiB; trying q4 KV) ===" >> "$RES"
for C in 32768 16384; do
  stop
  ( cd /home/JetsonOrin/Repositories/pi-arena2 && ./run_one.sh bonsai-a2-c$C $BIN \
    -m $M/Bonsai-27B-Q1_0.gguf -ngl 99 -fa on -ctk q4_0 -ctv q4_0 -c $C \
    -b 512 -ub 128 -np 1 --jinja --metrics --host 0.0.0.0 --port 8080 ) \
    2>&1 | tee "$R5/logs/bonsai-a2-c$C.log" | grep --line-buffered "^RESULT" >> "$RES"
  grep -q "bonsai-a2-c$C: pytest" "$RES" && ! grep -q "bonsai-a2-c$C: SERVER_FAILED" "$RES" && break
done
stop
echo "=== BONSAI RETRY COMPLETE ===" >> "$RES"
