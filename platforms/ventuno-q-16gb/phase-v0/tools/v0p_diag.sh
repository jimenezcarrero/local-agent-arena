#!/bin/bash
# v0p_diag.sh — pi tool-call diagnostic for NeoHorse-1-4B (D141, v0p-plan.txt). Diagnostic only: nothing here admits or
# qualifies a configuration. Four steps, each one fresh server through run_v0e.sh's evidence chain (run window, health
# check + fail-closed verdict, kernel audit, NPU stall watchdog), with pi_capture_proxy.py on :8080 in front of the
# server on :8090 (v0p_serve.sh) so the exact requests and raw responses are kept:
#   D1  NPU, the A-retry runtime of D139 at -c 32768, llama.cpp default sampling: 10 pi smoke sessions (captures pi's
#       first request), then 20 replays of that first request
#   D2  as D1 with the model card's sampling (temp 1.0, top_p 0.95, top_k 20, min_p 0, presence 1.5, repeat 1.0):
#       10 pi smoke sessions, 20 replays of D1's first request
#   D3  CPU, same binary and the same pure Q4_0 file (--device none -ngl 0, 4 big-core threads): 20 replays
#   D4  CPU, the publisher's Q4_K_M file (sha256 7da8ac62...): 20 replays
#   D5  (D145, run alone: STEPS=D5) as D1 with GGML_HEXAGON_GDN_SELECT=1 (GATED_DELTA_NET on the HVX kernel instead
#       of the HMX one, which fails test-backend-ops for >= 64-token batches): 10 pi sessions, 20 replays of D1's request
#   D6  (D154, STEPS=D6) as D1 with -ngl 32: the 32 blocks on the NPU, the output layer on the CPU
# NPU steps: a passing baseline probe first and htp_retry_check.sh before and after. Policy (D142): HANG or DEVFAULT
# anywhere -> fault recorded FIRST, recovery by probing, the post-run library check kept as extra evidence, STOP. A step
# must start from a fresh run directory, and a PASS needs the workload's complete evidence (its "WORKLOAD" line with
# all PI_N pi results and REPLAY_N replays, and the replay RESULT line); then any pass rate is a result. Steps D2-D4
# replay D1's request, bound by its sha256. Anything else (missing evidence, failed health, a replay error, a client
# crash, a stale directory, a library or file mismatch) -> STOP.
# Overridable for tests: BR, CHECK_PROC, RUN_V0E, HTPR_CHECK, STEP_PAUSE, STEPS + the runner's variables.
set -uo pipefail
source ~/v0/v0d_lib.sh
BR=${BR:-$HOME/bench-runs}; CHECK_PROC=${CHECK_PROC:-pgrep -f}; RUN_V0E=${RUN_V0E:-$HOME/v0/run_v0e.sh}
HTPR_CHECK=${HTPR_CHECK:-/bin/bash $HOME/v0/htp_retry_check.sh}; STEP_PAUSE=${STEP_PAUSE:-120}; STEPS=${STEPS:-D1 D2 D3 D4}
PH=v0p-pi; ST=$BR/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models; O=$BR/v0/$PH
QKM=${QKM:-$M/neohorse-q4km/NeoHorse-1-4B-Q4_K_M.gguf}; QKM_SHA=7da8ac6219b0aaa21b58cb26c1ec6826b478449215a3b0448742e1cda60fa2b4
mkdir -p $O $BR/v0/v0d; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done
  pkill -f '/v0/pi_capture_proxy.py' 2>/dev/null; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/q40/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
W="bash $HOME/v0/v0p_serve.sh"
NPU="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$HOME/v0/farf;$HOME/v0/htp-retry;$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/q40/NeoHorse-1-4B-q4_0-pure.gguf -c 32768 --cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8090 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
VENDOR="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --presence-penalty 1.5 --repeat-penalty 1.0"
CPU="env LD_LIBRARY_PATH=$P/lib $P/bin/llama-server -c 32768 --cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8090 --device none -ngl 0 -t 4 --cpu-mask 0xF --cpu-strict 1 --ctx-checkpoints 0"
$CHECK_PROC '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: NPU stall watchdog not running"; exit 6; }
$CHECK_PROC '^/bin/bash /home/arduino/v0/monitor/health_sampler.sh' > /dev/null || { say "STOP: health sampler not running"; exit 6; }
c=$($HTPR_CHECK 2>&1) || { say "STOP: $c"; exit 6; }
case " $STEPS " in *" D4 "*) [ "$(sha256sum "$QKM" 2>/dev/null | cut -d' ' -f1)" = "$QKM_SHA" ] || { say "STOP: $QKM missing or not sha256 $QKM_SHA"; exit 6; };; esac
lastres() { grep -oE 'RESULT (PASS|FAIL).*' $1/run.txt 2>/dev/null | tail -1; }
# step <label> <npu|cpu> <timeout s> <env for the workload...> -- <server command...>
step() { local lab=$1 kind=$2 to=$3; shift 3; local wenv=(); while [ "$1" != -- ]; do wenv+=("$1"); shift; done; shift
  local f0 wd0 rc C pn rn lc=ok
  [ -e $O/$lab ] && { say "STOP: $O/$lab already exists (a fresh run directory is required)"; exit 2; }
  if [ $kind = npu ]; then f0=$(nfaults); ready now
    [ "$(nfaults)" = "$f0" ] || { say "STOP: fault in the baseline before $lab (recovered)"; exit 3; }
    c=$($HTPR_CHECK 2>&1) || { say "STOP: before $lab: $c"; exit 2; }; fi
  say "START $lab"; wd0=$(wdcount)
  env "${wenv[@]}" CAP_DIR=$O/$lab/capture PHASE=$PH timeout -k 60 $to bash $RUN_V0E $lab $HOME/v0/v0p_workload.sh -- $W "$@" > /dev/null 2>&1; rc=$?; killall_srv
  C=$(classify $O/$lab $rc $wd0)
  say "END $lab: $C (runner rc $rc) | $(lastres $O/$lab) | $(grep -h "RESULT $lab:" $O/$lab/workload.txt 2>/dev/null | tail -1)"
  [ $kind = npu ] && { c=$($HTPR_CHECK 2>&1) || lc="FAILED: $c"; }
  case $C in
    HANG|DEVFAULT) fault $lab $C; [ "$lc" = ok ] || say "NOTE $lab: post-run library check $lc (kept as evidence)"
      ready wait; say "STOP: $C in $lab (recovered)"; exit 3;;
  esac
  [ "$lc" = ok ] || { say "STOP: after $lab: library check $lc"; exit 2; }
  [ $C = PASS ] || { say "STOP: $lab $C"; exit 2; }
  for e in "${wenv[@]}"; do case $e in PI_N=*) pn=${e#*=};; REPLAY_N=*) rn=${e#*=};; esac; done
  grep -qE "^WORKLOAD $lab: pi results $pn/$pn, replays $rn/$rn, request sha256 [0-9a-f]{64}$" $O/$lab/workload.txt 2>/dev/null \
    && grep -qE "^RESULT $lab: first-reply tool calls [0-9]+/$rn " $O/$lab/workload.txt \
    || { say "STOP: $lab: workload evidence incomplete (WORKLOAD/RESULT lines)"; exit 2; }
  [ $lab = v0p-D1 ] && { sha256sum $O/$lab/first-request.json 2>/dev/null | cut -d' ' -f1 > $O/$lab/first-request.sha256; [ -s $O/$lab/first-request.sha256 ] \
    || { say "STOP: D1 left no first-request.json"; exit 2; }; }
  sleep $STEP_PAUSE; }
say "v0p pi diagnostic start (pid $$): steps $STEPS, no root"
# Step caps cover the worst case of the declared work: NPU 10 pi sessions + 20 replays at 600 s each (18,000 s) plus
# load: 19,000 s; CPU 20 replays at 600 s (12,000 s) plus load: 13,000 s.
D1R="REPLAY_REQ=$O/v0p-D1/first-request.json"
d1sha() { local h; h=$(cat $O/v0p-D1/first-request.sha256 2>/dev/null)
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] && [ "$(sha256sum $O/v0p-D1/first-request.json 2>/dev/null | cut -d' ' -f1)" = "$h" ] \
    || { say "STOP: D1's first request and its sha256 are missing or do not match"; exit 2; }; echo $h; }
for s in $STEPS; do case $s in
  D1) step v0p-D1 npu 19000 PI_N=10 REPLAY_N=20 PI_MODEL=local32k -- $NPU;;
  D2) h=$(d1sha) || exit 2; step v0p-D2 npu 19000 PI_N=10 REPLAY_N=20 PI_MODEL=local32k $D1R REPLAY_SHA=$h -- $NPU $VENDOR;;
  D3) h=$(d1sha) || exit 2; step v0p-D3 cpu 13000 PI_N=0 REPLAY_N=20 $D1R REPLAY_SHA=$h -- $CPU -m $M/q40/NeoHorse-1-4B-q4_0-pure.gguf;;
  D4) h=$(d1sha) || exit 2; step v0p-D4 cpu 13000 PI_N=0 REPLAY_N=20 $D1R REPLAY_SHA=$h -- $CPU -m $QKM;;
  D6) h=$(d1sha) || exit 2; step v0p-D6 npu 19000 PI_N=10 REPLAY_N=20 PI_MODEL=local32k $D1R REPLAY_SHA=$h -- $NPU -ngl 32;;
  D5) h=$(d1sha) || exit 2; step v0p-D5 npu 19000 PI_N=10 REPLAY_N=20 PI_MODEL=local32k $D1R REPLAY_SHA=$h -- env GGML_HEXAGON_GDN_SELECT=1 $NPU;;
  *) say "STOP: unknown step $s"; exit 2;;
esac; done
say "v0p pi diagnostic complete (faults $(nfaults))"
