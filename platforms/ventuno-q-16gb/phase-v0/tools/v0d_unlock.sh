#!/bin/bash
# V0d "unlock" tests (D54), to run AFTER the final re-measurement and only after a cDSP reset (an NPU hang degrades
# the NPU until reset). Hypothesis (inferred from the failed-mapping sizes): each NPU session is a separate DSP
# process with a 32-bit address space, and large single buffers (KV cache, compute buffer, the 248K-vocab output
# layer) fail to map, not the session total. Tests keep every single buffer small:
#   -ngl <n_layer>  keeps the output layer (and the vocab-sized logits) on the CPU
#   GGML_HEXAGON_MBUF=256  splits weight buffers into <=256 MiB chunks
#   more sessions  shrinks each session's KV and recurrent buffers
# Load + 512 + 16K speed, single runs (rank only). A hang stops the script (the NPU then needs another reset).
set -uo pipefail
ST=~/bench-runs/v0/v0d/unlock-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
WD0=$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)
run() { local lab=$1 devs=$2 model=$3 ctx=$4; shift 4; say "START $lab"
  timeout -k 60 2400 ~/v0/run_route.sh $lab v0d-unlock --depths 512,16384 --nctx 40960 -- env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib \
    GGML_HEXAGON_DEVICES=$devs GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/$model -c $ctx --cache-ram 8192 -lv 4 --host 127.0.0.1 \
    --port 8080 --device $devs --ctx-checkpoints 0 "$@" > /dev/null 2>&1
  local o=~/bench-runs/v0/v0d-unlock/$lab
  say "END $lab | $(grep -o 'RESULT .*' $o/run.txt | tail -1 | cut -c1-70) | $(grep -h '^RESULT' $o/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+ prompt_tokens=[0-9None]+|prefill_tps=[^ ]+|decode_tps=[^ ]+' | paste -sd' ' | cut -c1-160) | $(grep -oE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+' $o/server.log | head -1)"
  for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 30
  [ "$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)" != "$WD0" ] && { say "STOP: NPU hang (watchdog) in $lab; needs a cDSP reset"; exit 2; }; }
say "unlock tests start"
run 9b-3s-mbuf256-outcpu   HTP0:0,HTP0:1,HTP0:2 Ornith-1.0-9B-q4_0-pure.gguf 40960 -ngl 33
run 9b-2s-mbuf256-outcpu   HTP0:0,HTP0:1        Ornith-1.0-9B-q4_0-pure.gguf 40960 -ngl 33
run 4b-2s-mbuf256-outcpu   HTP0:0,HTP0:1        NeoHorse-1-4B-q4_0-pure.gguf 40960 -ngl 32
run 4b-4s-mbuf256-65k      HTP0:0,HTP0:1,HTP0:2,HTP0:3 NeoHorse-1-4B-q4_0-pure.gguf 65536 -ngl 32
# n-gram speculative decoding (no draft model, no extra NPU memory). Feasibility only: rejected drafts need the
# recurrent state rolled back, the same state readback that crashed context checkpoints on HTP (D43).
run 4b-2s-ngram-mapk HTP0:0,HTP0:1 NeoHorse-1-4B-q4_0-pure.gguf 40960 -ngl 99 --spec-type ngram-map-k --spec-draft-n-max 16
# settle the cache-ram 0 anomaly (D53: 216.2/6.26 at 16K vs ~315/8.2): two plain runs, no MBUF/-ngl changes
for r in 1 2; do say "START cram0-repeat-$r"
  timeout -k 60 1800 ~/v0/run_route.sh 4b-2s-cram0-repeat-$r v0d-unlock --depths 512,16384 --nctx 40960 -- env LD_LIBRARY_PATH=$P/lib \
    ADSP_LIBRARY_PATH=$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 \
    --cache-ram 0 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 > /dev/null 2>&1
  say "END cram0-repeat-$r | $(grep -h '^RESULT' ~/bench-runs/v0/v0d-unlock/4b-2s-cram0-repeat-$r/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+|prefill_tps=[^ ]+|decode_tps=[^ ]+' | paste -sd' ')"
  for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 30; done
say "unlock tests done"
