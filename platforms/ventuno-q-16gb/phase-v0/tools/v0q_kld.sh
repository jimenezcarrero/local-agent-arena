#!/bin/bash
# v0q_kld.sh <out dir> <text file> (D146): numerical distance of the NPU from the CPU for NeoHorse-1-4B-q4_0-pure,
# and which op types account for it. llama-perplexity (release 836d57176) saves the CPU logits once
# (--kl-divergence-base), then every NPU arm computes the KL divergence and top-token agreement against them.
# NPU arms: D1's runtime (two sessions HTP0:0,HTP0:1, patched DSP library, -ub 512) with nothing filtered, with op
# fusion off, and with one op group at a time sent back to the CPU (GGML_HEXAGON_OPFILTER, a regex over
# ggml_op_desc). "all" (every op to the CPU) is the control: it must come out near zero.
# One arm at a time. npu_stall_watchdog.sh only watches llama-server/llama-bench, so each NPU arm has its own stall
# check with the watchdog's rule: a thread in fastrpc_wait_for_completion and < 0.5 core-s per 10 s for STALL_S
# (120 s) -> HANG: SIGKILL, thread states saved, STOP. Any other failure or a 1800 s timeout -> STOP.
# A load that fails with "buffer mapping failed" is reloaded once (D147). Overridable for tests: PPL, ARMS, STALL_S,
# ARM_PAUSE, RELOAD_PAUSE.
set -uo pipefail
O=$1; TXT=$2; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40/NeoHorse-1-4B-q4_0-pure.gguf
PPL=${PPL:-$P/bin/llama-perplexity}; STALL_S=${STALL_S:-120}
[ -e "$O" ] && { echo "$O exists; a fresh directory is required"; exit 2; }; mkdir -p "$O"
COMMON="-m $M -f $TXT -c 1024 -b 1024 -ub 512"
NPU_ENV=(LD_LIBRARY_PATH=$P/lib "ADSP_LIBRARY_PATH=$HOME/v0/htp-retry;$P/lib" GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1)
ARMS=${ARMS:-"npu nofusion all MUL_MAT|MUL_MAT_ID FLASH_ATTN_EXT|SOFT_MAX GATED_DELTA_NET SSM_CONV RMS_NORM|NORM|L2_NORM ROPE SWIGLU|GEGLU|REGLU|GLU SILU|SIGMOID|SOFTPLUS|EXP|NEG|GELU|TANH|ABS|RELU ADD|ADD_ID|MUL|SUB|DIV|SCALE|SQR|SQRT|CLAMP|SUM|SUM_ROWS|CUMSUM|TRI|SOLVE_TRI|FILL|DIAG CPY|CONT|DUP|SET_ROWS|GET_ROWS|CONCAT|PAD|REPEAT|ROLL|TRANSPOSE|PERMUTE|VIEW|RESHAPE"}
summ() { grep -E '^(Mean +KLD|Maximum KLD|99.9% +KLD|Median +KLD|Same top p|Mean PPL\(Q\)|RMS Δp)' "$1" | tr -s ' ' | paste -sd'|' -; }
# run_npu <log> <env...>: runs one NPU arm in the background with the stall check; echoes rc, or HANG
run_npu() { local log=$1; shift; local pid st=0 c0 c1 t
  env "$@" timeout 1800 $PPL $COMMON --device HTP0:0,HTP0:1 -ngl 99 --kl-divergence-base $O/cpu.kld --kl-divergence >> $log 2>&1 & pid=$!
  sleep 5; c0=$(cpu_ticks $pid)
  while kill -0 $pid 2>/dev/null; do sleep 10; c1=$(cpu_ticks $pid)
    if grep -qs fastrpc_wait_for_completion /proc/$pid/task/*/wchan $(pgrep -P $pid | sed 's|.*|/proc/&/task/*/wchan|') && [ $(( c1 - c0 )) -lt 50 ]; then st=$((st+10)); else st=0; fi
    c0=$c1
    if [ $st -ge $STALL_S ]; then for q in $(pgrep -P $pid) $pid; do for t in /proc/$q/task/*; do echo "$q $(awk '{print $3}' $t/stat) $(cat $t/wchan) $(cat $t/comm)"; done; done > $log.stall 2>&1
      pkill -KILL -P $pid; kill -KILL $pid; wait $pid 2>/dev/null; echo HANG; return; fi
  done; wait $pid; echo $?; }
# CPU ticks (USER_HZ=100) of the timeout process's child, the perplexity binary
cpu_ticks() { local c; c=$(pgrep -P $1 | head -1); awk '{print $14+$15}' /proc/${c:-$1}/stat 2>/dev/null || echo 0; }
env LD_LIBRARY_PATH=$P/lib timeout 3600 $PPL $COMMON --device none -ngl 0 -t 4 --kl-divergence-base $O/cpu.kld > $O/cpu.log 2>&1 \
  || { echo "CPU base failed (rc $?)"; exit 1; }
echo "base cpu: $(grep -oE 'Final estimate: PPL = [0-9.]+ \+/- [0-9.]+' $O/cpu.log)" | tee $O/summary.txt
i=0
for a in $ARMS; do i=$((i+1)); n=$(printf %02d $i); extra=(); args=()
  case $a in npu) ;; nofusion) extra=(GGML_HEXAGON_OPFUSION=0);; all) extra=("GGML_HEXAGON_OPFILTER=.*");; *) extra=("GGML_HEXAGON_OPFILTER=$a");; esac
  echo "arm $n $a env ${extra[*]:-none}" > $O/arm$n.log
  rc=$(run_npu $O/arm$n.log "${NPU_ENV[@]}" "${extra[@]}")
  # D147: a load-time "buffer mapping failed" (the intermittent map failure of D90) gets ONE reload after 60 s
  if [ "$rc" != 0 ] && [ "$rc" != HANG ] && grep -q 'buffer mapping failed' $O/arm$n.log; then
    mv $O/arm$n.log $O/arm$n-loadfail.log; echo "arm $n $a LOADFAIL (buffer mapping failed, rc $rc): one reload after ${RELOAD_PAUSE:-60} s" | tee -a $O/summary.txt
    sleep ${RELOAD_PAUSE:-60}; echo "arm $n $a env ${extra[*]:-none} (reload)" > $O/arm$n.log; rc=$(run_npu $O/arm$n.log "${NPU_ENV[@]}" "${extra[@]}"); fi
  echo "arm $n $a rc $rc | $(summ $O/arm$n.log)" | tee -a $O/summary.txt
  [ "$rc" = HANG ] && { echo "STOP: NPU stall in arm $n ($a); threads in arm$n.log.stall" | tee -a $O/summary.txt; exit 3; }
  [ $rc = 0 ] || { echo "STOP: arm $n rc $rc" | tee -a $O/summary.txt; exit 2; }
  sleep ${ARM_PAUSE:-20}
done
echo "done" >> $O/summary.txt
