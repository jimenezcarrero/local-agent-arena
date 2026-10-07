#!/bin/bash
# After the NPU hang at 23:44 (q8 KV, watchdog kill), the base 4B configuration stopped loading (fastrpc_mmap).
# Check whether the cDSP recovers on its own when idle: base-config load + 512 probe after 10 and 40 idle minutes.
ST=~/bench-runs/v0/v0d/status.txt; P=~/v0/hexpkg/pkg-linux
until grep -q 'v0d tune2 done\|STOP:' $ST; do sleep 20; done
for wait_min in 10 30; do
  sleep $((wait_min*60))
  lab=v0d-npu-recovery-$(date +%H%M)
  echo "$(date -Is) START $lab (after a further ${wait_min} idle min)" >> $ST
  timeout -k 60 900 ~/v0/run_route.sh $lab v0d-tune --depths 512 --nctx 40960 -- env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib \
    GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m ~/v0/models/q40/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 \
    --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 > /dev/null 2>&1
  o=~/bench-runs/v0/v0d-tune/$lab
  echo "$(date -Is) END $lab | $(grep -o 'RESULT .*' $o/run.txt | tail -1) | $(grep -oE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+' $o/server.log | head -1)" >> $ST
  grep -q 'RESULT PASS' $o/run.txt && { echo "$(date -Is) NPU RECOVERED (idle)" >> $ST; exit 0; }
done
echo "$(date -Is) NPU NOT RECOVERED after ~40 idle min: needs a cDSP restart or reboot (root)" >> $ST
