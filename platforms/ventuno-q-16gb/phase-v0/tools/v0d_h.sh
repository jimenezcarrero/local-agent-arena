#!/bin/bash
# V0d 9B configuration H (D63): G' without strict pinning. All three strict-pinning servers that hung the NPU did so
# on their second request (D57, D62, 9b-t4-strict-poll0); no non-strict ggml-hexagon server at the final settings
# has hung. H = 3 sessions, MBUF 256, -ngl 33 --no-op-offload, -t 4 (no mask, no strict): single run 16K 149.0/5.25.
# 1. Wait for NPU recovery (base 4B load + 512 every 15 min, up to 6 h).
# 2. H final re-measurement: warm-up + r1-r3 at 512/8K/16K/32K, both tool gates (3 min idle between loads).
# 3. Soak: 6 fresh loads each of A and H, alternating, 512/8K, 3 min idle between loads. Stops at an NPU hang.
set -uo pipefail
ST=~/bench-runs/v0/v0d/h-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=~/bench-runs/v0/v0d-final-9b-h
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; }
WD0=$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)
hung() { [ "$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)" != "$WD0" ]; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
A="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
H="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4"
res() { grep -h '^RESULT' $1/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+|prefill_tps=[^ ]+|decode_tps=[^ ]+' | awk '!s[$0]++' | paste -sd' '; }
step() { local lab=$1 dep=$2 to=$3 cmd=$4; say "START $lab"
  timeout -k 60 $to ~/v0/run_route.sh $lab v0d-final-9b-h --depths $dep --nctx 40960 -- $cmd > /dev/null 2>&1; killall_srv
  say "END $lab | $(grep -o 'RESULT .*' $O/$lab/run.txt | tail -1 | cut -c1-60) | $(res $O/$lab) | $(grep -oE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+' $O/$lab/server.log | head -1)"
  hung && { say "STOP: NPU hang in $lab"; exit 2; }; sleep 180; }
say "H start (pid $$); waiting for the NPU"; ok=0
for i in $(seq 1 24); do sleep 900; lab=probe-$(date +%H%M)
  timeout -k 60 900 ~/v0/run_route.sh $lab v0d-final-9b-h --depths 512 --nctx 40960 -- $A > /dev/null 2>&1; killall_srv
  r=$(grep -o 'RESULT .*' $O/$lab/run.txt | tail -1 | cut -c1-50); say "PROBE $lab | $r"
  case "$r" in *PASS*) ok=1; break;; esac; hung && { say "STOP: hang during a probe"; exit 2; }
done
[ $ok = 1 ] || { say "NPU did not recover in 6 h"; exit 1; }; sleep 180
for t in warmup r1 r2 r3; do step 9b-H-$t 512,8192,16384,32768 5400 "$H"; done
say "TOOLS 9b-H"; PHASE=v0d-final-9b-h timeout -k 60 9000 ~/v0/run_v0c.sh 9b-H-tools llama 0 -- $H > /dev/null 2>&1; killall_srv
say "TOOLS 9b-H: $(grep -o 'RESULT .*' $O/9b-H-tools/run.txt | tail -1 | cut -c1-140)"; hung && { say "STOP: hang in tools"; exit 2; }; sleep 180
for i in 1 2 3 4 5 6; do step soak-A-$i 512,8192 1800 "$A"; step soak-H-$i 512,8192 2400 "$H"; done
say "H done"
