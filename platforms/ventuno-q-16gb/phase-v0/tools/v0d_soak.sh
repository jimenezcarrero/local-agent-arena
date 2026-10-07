#!/bin/bash
# V0d stability check (D61): hang count under big-core affinity, which the 9B needs (D60) and which hung the NPU
# once on the 4B (D57). 6 fresh loads each, alternating 4B F and 9B G', requests at 512 and 8K. Characterisation
# only (a V0e marathon is the qualification). Stops at the first NPU hang.
set -uo pipefail
ST=~/bench-runs/v0/v0d/soak-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=~/bench-runs/v0/v0d-soak
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
WD0=$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)
BIG="-t 4 --cpu-mask 0xF --cpu-strict 1"; E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
F4="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 $BIG"
G9="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload $BIG"
say "soak start (pid $$)"
for i in 1 2 3 4 5 6; do for c in F4 G9; do lab=soak-$c-$i; say "START $lab"
  timeout -k 60 1800 ~/v0/run_route.sh $lab v0d-soak --depths 512,8192 --nctx 40960 -- ${!c} > /dev/null 2>&1
  say "END $lab | $(grep -o 'RESULT .*' $O/$lab/run.txt | tail -1 | cut -c1-60) | $(grep -h '^RESULT' $O/$lab/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+|prefill_tps=[^ ]+|decode_tps=[^ ]+' | awk '!s[$0]++' | paste -sd' ')"
  for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 30
  [ "$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)" != "$WD0" ] && { say "STOP: NPU hang in $lab"; exit 2; }
done; done
say "soak done: 12 loads, no hang"
