#!/bin/bash
# Probe the largest context that loads for a given model/binary.
set -u
BIN=/home/JetsonOrin/Repositories/llama.cpp-bailing/build/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models/Ling-3.0-tiny-Q3_K_M.gguf
LOG=/home/JetsonOrin/Repositories/round5-newmodels/logs

stop() {
  local p
  p=$(pgrep -f "llama.cpp-bailing/build/bin/llama-server" 2>/dev/null)
  [ -n "$p" ] && kill $p 2>/dev/null
  sleep 6
  for _ in $(seq 1 30); do ss -ltn 2>/dev/null | grep -q ':8080 ' || break; sleep 2; done
}

for spec in "131072 q4_0" "65536 q4_0" "32768 q4_0" "32768 f16" "16384 f16"; do
  set -- $spec; C=$1; KV=$2
  [ "$KV" = "f16" ] && KVA="" || KVA="-ctk $KV -ctv $KV"
  stop
  nohup $BIN -m $M -ngl 99 -fa on $KVA -c $C -np 1 --jinja \
    --host 127.0.0.1 --port 8080 > "$LOG/probe_${C}_${KV}.log" 2>&1 &
  ok=""
  for _ in $(seq 1 50); do
    curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q ok && { ok=1; break; }
    grep -qiE "out of memory|loading error" "$LOG/probe_${C}_${KV}.log" && break
    sleep 3
  done
  if [ -n "$ok" ]; then
    echo "Ling @ ${C} ${KV}: OK"
  else
    echo "Ling @ ${C} ${KV}: FAIL"
  fi
done
stop
