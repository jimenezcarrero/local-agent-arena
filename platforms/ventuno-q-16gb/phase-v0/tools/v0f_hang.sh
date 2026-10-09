#!/bin/bash
# v0f_hang.sh — NPU hang diagnostic (D122; diagnostic only, never a qualification). Hypothesis (code reading, D122):
# a lost-wakeup race in the DSP packet loop (htp/main.c process_ops) strands queued batches when another session asks
# for the VTCM; it needs >= 2 batches pending in one session's queue. Workaround under test: GGML_HEXAGON_OPQUEUE=1
# (at most one pending batch per session; host-side setting, no rebuild).
# Arms, interleaved (W1 B1 W2 B2 ...), each session one fresh server of configuration A at -c 32768 (the D118 command):
#   W  GGML_HEXAGON_OPQUEUE=1        B  default (32)
# Each session: 4B baseline probe (must PASS) -> server -> v0f_stress.py (N_REQ requests) -> classify.
# A HANG or DEVFAULT: recorded, recovery by baseline probing without a restart (ready wait), then the schedule goes on
# (counting hangs is the point). STOP: FAULT_CAP faults in total (default 8), a load failure twice in a row, a probe that
# never passes (ready() exits), missing evidence, or the end of the schedule. No root.
# Overridable for tests: BR, CHECK_PROC, RUN_V0E, SESS_PAUSE, N_SESS, N_REQ, FAULT_CAP + the runner's variables.
set -uo pipefail
source ~/v0/v0d_lib.sh
BR=${BR:-$HOME/bench-runs}; CHECK_PROC=${CHECK_PROC:-pgrep -f}
RUN_V0E=${RUN_V0E:-$HOME/v0/run_v0e.sh}; SESS_PAUSE=${SESS_PAUSE:-60}; N_SESS=${N_SESS:-10}
export N_REQ=${N_REQ:-40}; export FAULT_CAP=${FAULT_CAP:-8}
PH=v0f-hang; ST=$BR/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=$BR/v0/$PH
mkdir -p $O $BR/v0/v0d; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
SRV="$P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 32768 --cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
W_CMD="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 GGML_HEXAGON_OPQUEUE=1 $SRV"
B_CMD="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $SRV"
$CHECK_PROC '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: NPU stall watchdog not running"; exit 6; }
$CHECK_PROC '^/bin/bash /home/arduino/v0/monitor/health_sampler.sh' > /dev/null || { say "STOP: health sampler not running"; exit 6; }
say "v0f hang diagnostic start (pid $$): $N_SESS sessions per arm, $N_REQ requests each, fault cap $FAULT_CAP, no root"
lf=0
for k in $(seq 1 $N_SESS); do
  for arm in W B; do
    lab=v0f-$arm-$k; cmd=$W_CMD; [ $arm = B ] && cmd=$B_CMD
    ready now
    say "START $lab"; wd0=$(wdcount)
    PHASE=$PH timeout -k 60 3600 bash $RUN_V0E $lab $HOME/v0/v0f_stress.sh -- $cmd > /dev/null 2>&1; rc=$?; killall_srv
    C=$(classify $O/$lab $rc $wd0)
    n_ok=$(grep -c '"ok": true' $O/$lab/stress.jsonl 2>/dev/null); say "END $lab: $C | requests ok ${n_ok:-0} | $(grep -h 'RESULT' $O/$lab/run.txt 2>/dev/null | tail -1)"
    case $C in
      PASS) lf=0;;
      HANG|DEVFAULT) lf=0; fault $lab $C; ready wait;;
      *) if grep -q 'SERVER EXITED before ready' $O/$lab/run.txt 2>/dev/null; then lf=$((lf+1))
           [ $lf -ge 2 ] && { say "STOP: two load failures in a row"; exit 2; }; ready wait
         elif grep -q 'RESULT FAIL: workload=1$' $O/$lab/run.txt 2>/dev/null; then say "NOTE $lab: a request error without a server loss (recorded)"
         else say "STOP: $lab $C"; exit 2; fi;;
    esac
    sleep $SESS_PAUSE
  done
done
say "v0f hang diagnostic complete: faults $(nfaults)"
