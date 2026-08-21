#!/bin/bash
# Find a base Qwen3.5-9B quant that fits a BIG window, then run arena 4 there.
# IQ4_XS (5.47 GB) OOMs at 65K; UD-IQ3_XXS is 4.30 GB (under Ornith's 4.66 GB).
# NOTE: different quant from the IQ4_XS used in arenas 1-3 - flag when reporting.
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
RES="$R5/qwen9b-bigwindow.txt"
F=$M/Qwen3.5-9B-base-UD-IQ3_XXS.gguf
ARGS="-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -np 1 --jinja --metrics -b 512 -ub 128"

while pgrep -f "run_lfm2.sh|run_gaps.sh" >/dev/null; do sleep 60; done
: > "$RES"
stop(){ local p; p=$(pgrep -f "build-novmm/bin/llama-server" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null; sleep 10
        for _ in $(seq 1 40); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
        sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; sleep 2; }

echo "=== base Qwen3.5-9B: find a quant that fits a big window ===" >> "$RES"
if [ ! -s "$F" ]; then
  echo "downloading UD-IQ3_XXS (4.30 GB)..." >> "$RES"
  curl -fL -s -o "$F" "https://huggingface.co/unsloth/Qwen3.5-9B-MTP-GGUF/resolve/main/Qwen3.5-9B-UD-IQ3_XXS.gguf" || { echo "download FAILED" >> "$RES"; exit 1; }
fi
echo "file: $(stat -c%s "$F" | awk '{printf "%.2f GB", $1/1e9}')" >> "$RES"

BEST=""
for C in 98304 65536 49152 32768; do
  stop
  nohup $BIN -m "$F" $ARGS -c $C --host 127.0.0.1 --port 8080 > "$R5/logs/q9b-xxs-$C.log" 2>&1 &
  ok=""
  for _ in $(seq 1 90); do
    curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q ok && { ok=1; break; }
    grep -qiE "out of memory|error loading|exiting due to" "$R5/logs/q9b-xxs-$C.log" && break
    sleep 4
  done
  if [ -n "$ok" ]; then
    R=$(curl -s -m 600 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"x","messages":[{"role":"user","content":"Count 1 to 30."}],"max_tokens":120}' 2>/dev/null \
      | python3 -c "import json,sys;t=json.load(sys.stdin)['timings'];print('tg %.2f t/s'%t['predicted_per_second'])" 2>/dev/null)
    echo "ctx $C: *** FITS *** $R" >> "$RES"; BEST=$C; break
  else
    echo "ctx $C: no — $(grep -oiE 'allocating [0-9.]+ MiB' "$R5/logs/q9b-xxs-$C.log" | tail -1)" >> "$RES"
  fi
done
stop

if [ -n "$BEST" ]; then
  echo "=== arena 4 big window @ $BEST (completes the tuning comparison) ===" >> "$RES"
  ( cd /home/JetsonOrin/Repositories/pi-arena4 && ./run_crusher.sh qwen9b-a4-big2 local $BIN -m "$F" $ARGS -c $BEST --host 0.0.0.0 --port 8080 ) \
    2>&1 | tee "$R5/logs/qwen9b-a4-big2.log" | grep --line-buffered -E "^RESULT|^TURN" >> "$RES"
  stop
else
  echo "no window fits - base Qwen-9B cannot run the big-window crusher on this board" >> "$RES"
fi
echo "=== QWEN9B BIG WINDOW COMPLETE ===" >> "$RES"
