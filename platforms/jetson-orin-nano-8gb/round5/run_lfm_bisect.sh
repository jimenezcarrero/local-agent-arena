#!/bin/bash
# Why did LFM2.5 start passing? Two variables changed at once: the llama.cpp
# build and the flags. Hold flags constant, swap only the binary.
set -u
OLD=/home/JetsonOrin/.local/bin/llama          # b10217 (llama.app) - the failing era
NEW=/home/JetsonOrin/Repositories/llama.cpp/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
RES="$R5/lfm-bisect.txt"
FLAGS="-ngl 99 -fa on -np 1 --jinja --metrics -ctk q4_0 -ctv q4_0 -c 65536 -b 512 -ub 128 --temp 0.1 --top-k 50 --repeat-penalty 1.1 --host 0.0.0.0 --port 8080"
while ps -eo args | grep -q "[b]uild-novmm/bin/llama-server"; do sleep 60; done
: > "$RES"
stop(){ for pat in "build-novmm/bin/llama-server" "^/home/JetsonOrin/\.local/bin/llama serve"; do
          p=$(pgrep -f "$pat" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null; done
        sleep 10; for _ in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
        sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; sleep 2; }

echo "=== LFM2.5 bisect: same flags, same quant, different llama.cpp build ===" >> "$RES"
echo "if OLD fails and NEW passes -> the llama.cpp version fixed it" >> "$RES"
echo "if both pass              -> the FLAGS were the fix, not the version" >> "$RES"
stop
( cd /home/JetsonOrin/Repositories/pi-shootout && ./run_one.sh lfm-oldbin $OLD serve -m $M/LFM2.5-2.6B-Q8_0.gguf $FLAGS ) \
  2>&1 | tee "$R5/logs/lfm-oldbin.log" | grep --line-buffered "^RESULT" >> "$RES"
echo "old-binary failure mode: $(grep -oiE 'Invalid diff|not found at start' /home/JetsonOrin/Repositories/pi-shootout/pi_lfm-oldbin.log 2>/dev/null | head -1 | tr -d '\n')" >> "$RES"
stop
echo "=== BISECT COMPLETE ===" >> "$RES"
