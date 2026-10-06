#!/bin/bash
# D61: after round 5 the NPU stopped mapping the base 4B configuration with NO hang (first seen 06:29). Probe the base
# config (load + 512) every 15 min for up to 6 h to time the idle recovery; on recovery, re-run the soak (v0d_soak.sh).
ST=~/bench-runs/v0/v0d/soak-status.txt; P=~/v0/hexpkg/pkg-linux
for i in $(seq 1 24); do
  sleep 900; lab=npu-probe-$(date +%H%M)
  timeout -k 60 900 ~/v0/run_route.sh $lab v0d-soak --depths 512 --nctx 40960 -- env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib \
    GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m ~/v0/models/q40/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 \
    --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 > /dev/null 2>&1
  for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done
  o=~/bench-runs/v0/v0d-soak/$lab
  echo "$(date -Is) PROBE $lab | $(grep -o 'RESULT .*' $o/run.txt | tail -1 | cut -c1-60) | $(grep -oE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+' $o/server.log | head -1)" >> $ST
  if grep -q 'RESULT PASS' $o/run.txt; then echo "$(date -Is) NPU RECOVERED (idle); restarting the soak" >> $ST; sleep 60; exec ~/v0/v0d_soak.sh; fi
done
echo "$(date -Is) NPU NOT RECOVERED after 6 h idle probes; needs a cDSP restart (root)" >> $ST
