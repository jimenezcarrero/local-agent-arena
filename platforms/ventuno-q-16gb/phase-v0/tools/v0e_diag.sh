#!/bin/bash
# v0e_diag.sh — D115 diagnostic after V0e H2 attempt 2 (3/3 load failures at -c 32768): does the admitted H2 command
# (-c 40960, v0d_admit.sh H) still load now? One cycle: cDSP restart + settle -> 4B baseline probe -> H2 at -c 40960,
# 512-token speed probe (run_route.sh). Not a qualification run. Exit 0 PASS, 1 LOADFAIL, 3 fault, 2 anything else.
set -uo pipefail
source ~/v0/v0d_lib.sh
BR=$HOME/bench-runs; PH=v0e-H2-diag; ST=$BR/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=$BR/v0/$PH
mkdir -p $O; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
H="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 5364 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4 --no-host"
pgrep -f '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: watchdog not running"; exit 2; }
/bin/bash ~/v0/cdsp_pre.sh >> $O/pre-load.txt 2>&1 || { say "STOP: restart failed: $(tail -1 $O/pre-load.txt)"; exit 2; }
say "PRE-LOAD: $(tail -1 $O/pre-load.txt)"
f0=$(nfaults); ready now; [ "$(nfaults)" = "$f0" ] || { say "fault in the baseline"; exit 3; }
say "START H2-40960"; wd0=$(wdcount)
timeout -k 60 1800 $RUN_ROUTE H2-40960 $PH --depths 512 --nctx 40960 -- $H > /dev/null 2>&1; rc=$?; killall_srv
c=$(classify $O/H2-40960 $rc $wd0); say "END H2-40960: $c | $(summary $O/H2-40960)"
case $c in PASS) exit 0;; LOADFAIL) exit 1;; HANG|DEVFAULT) fault H2-40960 $c; ready wait; exit 3;; *) exit 2;; esac
