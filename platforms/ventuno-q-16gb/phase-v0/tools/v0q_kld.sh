#!/bin/bash
# v0q_kld.sh <out dir> <text file> (D146): numerical distance of the NPU from the CPU for NeoHorse-1-4B-q4_0-pure,
# and which op types account for it. llama-perplexity (release 836d57176) saves the CPU logits once
# (--kl-divergence-base), then every NPU arm computes the KL divergence and top-token agreement against them.
# NPU arms: D1's runtime (two sessions HTP0:0,HTP0:1, patched DSP library, -ub 512) with nothing filtered, with op
# fusion off, and with one op group at a time sent back to the CPU (GGML_HEXAGON_OPFILTER, a regex over
# ggml_op_desc). "all" (every compute op to the CPU; NONE/VIEW/RESHAPE/PERMUTE/TRANSPOSE stay, D148: filtering NONE
# aborts the scheduler on the NPU-resident caches) is the control: it must come out near zero.
# One arm at a time. npu_stall_watchdog.sh only watches llama-server/llama-bench, so each NPU arm has its own stall
# check with the watchdog's rule: a thread in fastrpc_wait_for_completion and < 0.5 core-s per 10 s for STALL_S
# (120 s) -> HANG: SIGKILL, thread states saved, STOP. Any other failure or a 1800 s timeout -> STOP.
# An arm "env:K=V,K=V" sets environment variables instead of a filter (D151); an arm
# "args:F,V,..." appends flags to the NPU command, which override the defaults (D152). A load that fails with "buffer mapping failed" is reloaded once (D147). Overridable for tests: PPL, ARMS, STALL_S,
# ARM_PAUSE, RELOAD_PAUSE.
# D156 (Codex review of 8265a10): rc 0 is not a result. llama-perplexity exits 0 even when kl_divergence stops early
# ("failed reading log-probs"), so the base must show its chunk count, the running PPL of its last chunk, a finite
# final PPL and a non-empty logits file, and every arm the same chunk count, one table row per chunk, finite
# Mean PPL(Q), Mean KLD and Same top p, and no kl_divergence failure line. Otherwise STOP (base exit 1, arm exit 4),
# the log kept as it is.
set -uo pipefail
O=$1; TXT=$2; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40/NeoHorse-1-4B-q4_0-pure.gguf
PPL=${PPL:-$P/bin/llama-perplexity}; STALL_S=${STALL_S:-120}
[ -e "$O" ] && { echo "$O exists; a fresh directory is required"; exit 2; }; mkdir -p "$O"
COMMON="-m $M -f $TXT -c 1024 -b 1024 -ub 512"
DEVS=${DEVS:-HTP0:0,HTP0:1}  # D150: DEVS=HTP0:0 runs the arms on one session
NPU_ENV=(LD_LIBRARY_PATH=$P/lib "ADSP_LIBRARY_PATH=$HOME/v0/htp-retry;$P/lib" GGML_HEXAGON_DEVICES=$DEVS)
ARMS=${ARMS:-"npu nofusion MUL_MAT|MUL_MAT_ID FLASH_ATTN_EXT|SOFT_MAX GATED_DELTA_NET SSM_CONV RMS_NORM|NORM|L2_NORM ROPE SWIGLU|GEGLU|REGLU|GLU SILU|SIGMOID|SOFTPLUS|EXP|NEG|GELU|TANH|ABS|RELU ADD|ADD_ID|MUL|SUB|DIV|SCALE|SQR|SQRT|CLAMP|SUM|SUM_ROWS|CUMSUM|TRI|SOLVE_TRI|FILL|DIAG CPY|CONT|DUP|SET_ROWS|GET_ROWS|CONCAT|PAD|REPEAT|ROLL"}
xargs=()
summ() { grep -E '^(Mean +KLD|Maximum KLD|99.9% +KLD|Median +KLD|Same top p|Mean PPL\(Q\)|RMS Δp)' "$1" | tr -s ' ' | paste -sd'|' -; }
num='-?[0-9]+(\.[0-9]+)?'
# base_check: sets NCH (chunks) or WHY
base_check() { local l=$O/cpu.log; WHY=""
  NCH=$(grep -oE 'calculating perplexity over [0-9]+ chunks' $l | grep -oE '[0-9]+' | head -1)
  [ -n "$NCH" ] && [ "$NCH" -gt 0 ] || { WHY="no chunk count"; return 1; }
  grep -qE "\[$NCH\]$num," $l || { WHY="running PPL of chunk $NCH missing"; return 1; }
  grep -qE "Final estimate: PPL = $num \+/- $num" $l || { WHY="no finite final PPL"; return 1; }
  [ -s $O/cpu.kld ] || { WHY="logits file missing or empty"; return 1; }; }
# arm_check <log>: the arm's measurements are complete and finite, or WHY
arm_check() { local l=$1; WHY=""
  grep -qE "kl_divergence: .*fail" $l && { WHY="$(grep -m1 -E 'kl_divergence: .*fail' $l)"; return 1; }
  grep -qE "kl_divergence: computing over $NCH chunks" $l || { WHY="chunk count is not $NCH"; return 1; }
  [ "$(grep -cE "^ +[0-9]+ +$num ± " $l)" = "$NCH" ] && grep -qE "^ +$NCH +$num ± " $l || { WHY="not $NCH chunk rows"; return 1; }
  grep -qE "^Mean PPL\(Q\) +: +$num ± " $l || { WHY="no finite Mean PPL(Q)"; return 1; }
  grep -qE "^Mean +KLD: +$num ± " $l || { WHY="no finite Mean KLD"; return 1; }
  grep -qE "^Same top p: +$num ± " $l || { WHY="no finite Same top p"; return 1; }; }
# run_npu <log> <env...>: runs one NPU arm in the background with the stall check; echoes rc, or HANG
run_npu() { local log=$1; shift; local pid st=0 c0 c1 t
  env "$@" timeout 1800 $PPL $COMMON --device $DEVS -ngl 99 "${xargs[@]}" --kl-divergence-base $O/cpu.kld --kl-divergence >> $log 2>&1 & pid=$!
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
base_check || { echo "STOP: CPU base incomplete: $WHY" | tee $O/summary.txt; exit 1; }
echo "base cpu: $(grep -oE 'Final estimate: PPL = [0-9.]+ \+/- [0-9.]+' $O/cpu.log)" | tee $O/summary.txt
i=0
for a in $ARMS; do i=$((i+1)); n=$(printf %02d $i); extra=(); xargs=()
  case $a in npu) ;; nofusion) extra=(GGML_HEXAGON_OPFUSION=0);; all) extra=("GGML_HEXAGON_OPFILTER=(?!(NONE|VIEW|RESHAPE|PERMUTE|TRANSPOSE)$).*");;
    env:*) IFS=, read -ra extra <<< "${a#env:}";;  # D151: kernel selectors, e.g. env:GGML_HEXAGON_MM_SELECT=1
    args:*) IFS=, read -ra xargs <<< "${a#args:}";;  # D152: flags after the defaults (later ones win), e.g. args:-ub,1
    *) extra=("GGML_HEXAGON_OPFILTER=$a");; esac
  echo "arm $n $a env ${extra[*]:-none}" > $O/arm$n.log
  rc=$(run_npu $O/arm$n.log "${NPU_ENV[@]}" "${extra[@]}")
  # D147: a load-time "buffer mapping failed" (the intermittent map failure of D90) gets ONE reload after 60 s
  if [ "$rc" != 0 ] && [ "$rc" != HANG ] && grep -q 'buffer mapping failed' $O/arm$n.log; then
    mv $O/arm$n.log $O/arm$n-loadfail.log; echo "arm $n $a LOADFAIL (buffer mapping failed, rc $rc): one reload after ${RELOAD_PAUSE:-60} s" | tee -a $O/summary.txt
    sleep ${RELOAD_PAUSE:-60}; echo "arm $n $a env ${extra[*]:-none} (reload)" > $O/arm$n.log; rc=$(run_npu $O/arm$n.log "${NPU_ENV[@]}" "${extra[@]}"); fi
  echo "arm $n $a rc $rc | $(summ $O/arm$n.log)" | tee -a $O/summary.txt
  [ "$rc" = HANG ] && { echo "STOP: NPU stall in arm $n ($a); threads in arm$n.log.stall" | tee -a $O/summary.txt; exit 3; }
  # D149: the scheduler refuses at load a filter that would move an op on an NPU-resident cache view to the CPU;
  # nothing ran on the NPU, so the arm is recorded NOT RUNNABLE and the next one runs
  if [ $rc != 0 ] && grep -q 'that cannot run the operation' $O/arm$n.log; then
    echo "arm $n $a NOT RUNNABLE: $(grep -om1 'pre-allocated tensor.*' $O/arm$n.log)" | tee -a $O/summary.txt; sleep ${ARM_PAUSE:-20}; continue; fi
  [ $rc = 0 ] || { echo "STOP: arm $n rc $rc" | tee -a $O/summary.txt; exit 2; }
  arm_check $O/arm$n.log || { echo "STOP: arm $n ($a) rc 0 without complete measurements: $WHY" | tee -a $O/summary.txt; exit 4; }
  sleep ${ARM_PAUSE:-20}
done
echo "done" >> $O/summary.txt
