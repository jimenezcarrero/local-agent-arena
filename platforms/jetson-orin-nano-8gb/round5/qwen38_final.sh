#!/bin/bash
# Final Qwen3.8-27B GPU attempt: NO_VMM build + --no-mmap, headless.
# Steps -ngl down until inference actually produces tokens (not just loads).
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
R5=/home/JetsonOrin/Repositories/round5-newmodels
OUT=$R5/qwen38-final-results.txt   # its OWN file - never mixed with earlier runs
STATUS=$R5/qwen38-status.env

w() { grep -v "^$1=" "$STATUS" 2>/dev/null > "$STATUS.t" || true; echo "$1=$2" >> "$STATUS.t"; mv "$STATUS.t" "$STATUS"; }
: > "$STATUS"; w STATE running; w MODE "novmm-nommap"; w TOTAL_STEPS 3; w STEP 0
w ERRORS 0; w PID $$; w RUN_STARTED "$(date +%s)"; w STEP_STARTED "$(date +%s)"; w PHASE starting; w STEP_LABEL "-"; w RESULTS_FILE "$OUT"

RUNID="run-$(cat /proc/sys/kernel/random/boot_id | cut -c1-8)-$(cut -d. -f1 /proc/uptime)s"
: > "$OUT"                      # fresh file each run: nothing old can survive here
{
  echo "=== QWEN3.8 FINAL (NO_VMM build + --no-mmap) ==="
  echo "run id     : $RUNID"
  echo "wall clock : $(date)   (may read 1970 if NTP has not synced yet - use run id)"
  echo "uptime     : $(cut -d" " -f1 /proc/uptime)s since boot"
  echo "binary     : $BIN"
  echo "free start : $(free -m | awk 'NR==2{print $7}') MB"
  echo "---"
} >> "$OUT"

stop() { local p; p=$(pgrep -f "build-novmm/bin/llama-server" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null; sleep 8; }

step=0
for spec in "IQ1_S:Qwen3.8-27B-UD-IQ1_S.gguf" "IQ1_M:Qwen3.8-27B-UD-IQ1_M.gguf" "IQ2_XXS:Qwen3.8-27B-UD-IQ2_XXS.gguf"; do
  IFS=: read -r label file <<< "$spec"
  step=$((step+1)); w STEP $step; w STEP_LABEL "$label"; w STEP_STARTED "$(date +%s)"
  done_one=""
  for ngl in 99 64 48 32 20 12 0; do
    w PHASE "trying ngl=$ngl"
    stop
    nohup $BIN -m "$M/$file" -ngl $ngl -fa off --no-mmap -c 512 -np 1 --jinja \
      --host 127.0.0.1 --port 8099 > "$R5/logs/final-$label-$ngl.log" 2>&1 &
    ok=""
    for _ in $(seq 1 120); do
      curl -s http://127.0.0.1:8099/health 2>/dev/null | grep -q ok && { ok=1; break; }
      grep -qiE "out of memory|error loading|exiting due to" "$R5/logs/final-$label-$ngl.log" && break
      sleep 3
    done
    [ -z "$ok" ] && { echo "$label ngl=$ngl: load FAIL" >> "$OUT"; continue; }
    w PHASE "generating ngl=$ngl"
    r=$(curl -s -m 1800 http://127.0.0.1:8099/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"x","messages":[{"role":"user","content":"Say OK."}],"max_tokens":16}' 2>/dev/null \
      | python3 -c "
import json,sys
try:
    t=json.load(sys.stdin)['timings']
    print('pp %.2f t/s | tg %.2f t/s'%(t['prompt_per_second'],t['predicted_per_second']))
except Exception: print('GEN-FAILED')" 2>/dev/null)
    if [ "$r" = "GEN-FAILED" ] || [ -z "$r" ]; then
      echo "$label ngl=$ngl: loaded but generation FAILED" >> "$OUT"
    else
      echo "$label ngl=$ngl: *** WORKS *** $r" >> "$OUT"; done_one=1; stop; break
    fi
    stop
  done
  [ -z "$done_one" ] && echo "$label: no working config" >> "$OUT"
done
stop; w PHASE done; w STATE complete; w FINISHED "$(date +%s)"
echo "=== FINAL RUN COMPLETE $(date) ===" >> "$OUT"
