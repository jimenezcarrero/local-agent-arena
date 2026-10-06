#!/bin/bash
# V0d final re-measurement (RUNBOOK V0d step 3), starts only when the NPU loads the base configuration again.
# Final = A only (D57: F hung the NPU in 1 of 3 runs; A has 0 hangs in ~20). F kept as evidence in v0d-final-attempt1/.
# A = V0c candidate (2 sessions, ctx-checkpoints 0, defaults). Not included: KV q8_0 (hangs the NPU), cache-ram 0.
# Steps: NPU readiness probe (base load + 512) every 10 min for up to 6 h; then one discarded warm-up per config,
# 3 interleaved repeats at 512/8K/16K/32K (run_route.sh), then both tool gates on F (run_v0c.sh). Stops after an NPU
# hang (the NPU stays degraded until reset; D53).
set -uo pipefail
ST=~/bench-runs/v0/v0d/final-status.txt; mkdir -p ~/bench-runs/v0/v0d
P=~/v0/hexpkg/pkg-linux; N4=~/v0/models/q40/NeoHorse-1-4B-q4_0-pure.gguf
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
cleanup() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do say "cleanup: killing leftover server $pid"; kill -KILL $pid; done; sleep 5; }
srv() { echo env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $N4 \
  -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 "$@"; }
SRV_A=$(srv); SRV_F=$(srv -t 4 --cpu-mask 0xF --cpu-strict 1)
hung() { [ "$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)" != "$WD0" ]; }
WD0=$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)
say "v0d final start (pid $$)"
# wait for the recovery-check script to finish, then probe readiness
while ps -eo args | grep -q '^/bin/bash /home/arduino/v0/npu_recovery_check.sh'; do sleep 30; done
ok=0
for i in $(seq 1 36); do
  lab=v0d-final-ready-$(date +%H%M)
  timeout -k 60 900 ~/v0/run_route.sh $lab v0d-final --depths 512 --nctx 40960 -- $SRV_A > /dev/null 2>&1; cleanup
  if grep -q 'RESULT PASS' ~/bench-runs/v0/v0d-final/$lab/run.txt 2>/dev/null; then say "NPU ready ($lab)"; ok=1; break; fi
  say "NPU not ready ($lab: $(grep -oE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+' ~/bench-runs/v0/v0d-final/$lab/server.log | head -1)); retry in 10 min"
  sleep 600
done
[ $ok = 1 ] || { say "NPU never became ready; final re-measurement not run"; exit 1; }
rep() { local c=$1 tag=$2 s; [ $c = A ] && s=$SRV_A || s=$SRV_F
  say "REPEAT $c $tag"; timeout -k 60 3600 ~/v0/run_route.sh "neohorse4b-$c-$tag" v0d-final --depths 512,8192,16384,32768 --nctx 40960 -- $s > /dev/null 2>&1
  say "REPEAT $c $tag: $(grep -o 'RESULT .*' ~/bench-runs/v0/v0d-final/neohorse4b-$c-$tag/run.txt | tail -1 | cut -c1-120)"; cleanup
  hung && { say "STOP: NPU hang during $c $tag (watchdog); the NPU needs a reset"; exit 2; }
  sleep 60; }
for c in A; do rep $c warmup; done
for r in 1 2 3; do for c in A; do rep $c r$r; done; done
say "TOOLS A"
PHASE=v0d-final timeout -k 60 7200 ~/v0/run_v0c.sh neohorse4b-A-tools llama 0 -- $SRV_A > /dev/null 2>&1
say "TOOLS A: $(grep -o 'RESULT .*' ~/bench-runs/v0/v0d-final/neohorse4b-A-tools/run.txt | tail -1 | cut -c1-140)"; cleanup
say "v0d final done"
