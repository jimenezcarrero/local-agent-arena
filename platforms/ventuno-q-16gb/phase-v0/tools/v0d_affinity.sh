#!/bin/bash
# V0d affinity variants for the 9B (D62). F-style strict pinning (-t 4 --cpu-mask 0xF --cpu-strict 1) hung the NPU
# twice (D57, D61 soak); A (defaults) never has. The 9B needs some placement: defaults give 16K 143.5/3.90.
# 1. Wait for the NPU: base 4B load + 512 every 15 min, up to 6 h.
# 2. 9B G config + one placement variant per fresh load (512/16K), 3 min idle between loads (the soak showed a load
#    30 s after another can fail to map). A failed mapping is retried once after 15 min. Stops at an NPU hang.
set -uo pipefail
ST=~/bench-runs/v0/v0d/affinity-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=~/bench-runs/v0/v0d-affinity
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; }
WD0=$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)
hung() { [ "$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)" != "$WD0" ]; }
say "affinity tests start (pid $$); waiting for the NPU"
ok=0
for i in $(seq 1 24); do sleep 900; lab=probe-$(date +%H%M)
  timeout -k 60 900 ~/v0/run_route.sh $lab v0d-affinity --depths 512 --nctx 40960 -- env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib \
    GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 \
    --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 > /dev/null 2>&1; killall_srv
  r=$(grep -o 'RESULT .*' $O/$lab/run.txt | tail -1 | cut -c1-50); say "PROBE $lab | $r | $(grep -oE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+' $O/$lab/server.log | head -1)"
  case "$r" in *PASS*) ok=1; break;; esac
  hung && { say "STOP: NPU hang during a probe"; exit 2; }
done
[ $ok = 1 ] || { say "NPU did not recover in 6 h"; exit 1; }
sleep 180
v9() { local lab=$1; shift
  for attempt in 1 2; do say "START $lab (attempt $attempt)"
    timeout -k 60 2400 ~/v0/run_route.sh $lab v0d-affinity --depths 512,16384 --nctx 40960 -- env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib \
      GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 \
      --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload "$@" > /dev/null 2>&1
    killall_srv
    say "END $lab | $(grep -o 'RESULT .*' $O/$lab/run.txt | tail -1 | cut -c1-60) | $(grep -h '^RESULT' $O/$lab/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+|prefill_tps=[^ ]+|decode_tps=[^ ]+' | awk '!s[$0]++' | paste -sd' ') | $(grep -oE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+' $O/$lab/server.log | head -1)"
    hung && { say "STOP: NPU hang in $lab"; exit 2; }
    grep -q 'SERVER EXITED before ready' $O/$lab/run.txt && [ $attempt = 1 ] && { mv $O/$lab $O/$lab-loadfail1; sleep 900; continue; }
    break
  done; sleep 180; }
v9 9b-t4        -t 4
v9 9b-t4-mask   -t 4 --cpu-mask 0xF
v9 9b-t4-strict-poll0 -t 4 --cpu-mask 0xF --cpu-strict 1 --poll 0
say "affinity tests done"
