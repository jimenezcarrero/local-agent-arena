#!/bin/bash
# v0d_recover.sh <phase>: the runner's standard fault recovery on its own (D105). Idle PROBE_WAIT (900 s), then the
# unchanged 4B baseline probe, repeated up to 13 times (ready wait in v0d_runner.sh). No cDSP restart, no other load.
# Writes probe-<time> runs and status lines into the given phase.
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=$1; ST=~/bench-runs/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=~/bench-runs/v0/$PH
mkdir -p $O; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
pgrep -f '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: NPU stall watchdog not running"; exit 6; }
pgrep -f '^/bin/bash /home/arduino/v0/monitor/health_sampler.sh' > /dev/null || { say "STOP: health sampler not running"; exit 6; }
say "recovery start (pid $$): idle ${PROBE_WAIT}s, then baseline probe (no restart)"; ready wait; say "recovery done rc=$?"
