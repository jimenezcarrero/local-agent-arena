#!/bin/bash
# v0e_A_retry.sh — V0e qualification of A at window 32768 with the patched DSP library (D136, v0e-plan-A-retry.txt).
# v0e_A.sh (D118) unchanged except: the server loads ~/v0/htp-retry/libggml-htp-v75.so (the htp_main_thread retry
# patch, D131; sha256 checked before and after every session, a mismatch stops) and keeps DSP error logging on
# (~/v0/farf/llama-server.farf, mask 0x1f, D125), whose journal lines are exported after every session; retried
# dspqueue_peek errors are counted and reported, never a fault by themselves. Baseline probes stay on the release
# package (the NPU health check used throughout). No cDSP restart, no root.
# Two server sessions, each preceded by a passing 4B baseline probe:
#   S1  steps 1-3 (v0e_s1.sh): streaming tool gates, pi smoke, window agreement / near-limit / tool continuation, cached
#       reuse with real tool results, real-pi compaction
#   S2  step 4 (v0e_sustained.sh): one server kept up >= 95 min under a repeating workload; VALID sustained summary
# Each session: classify() + memfloor --admit 7942 (A's cache cap). Policy, declared before running:
#   - HANG or DEVFAULT anywhere (baseline probes included) -> fault recorded; recovery (probing until a baseline PASS,
#     no restart); STOP: A NOT QUALIFIED in this V0e attempt.
#   - S1 with failed items but a clean server session -> S1 FAIL recorded; S2 still runs (evidence); not qualified.
#   - a clean load failure (D114 rule, declared up front here): recovery, then that session once more; twice -> STOP:
#     NOT QUALIFIED (load). A fault during that recovery -> NOT QUALIFIED.
#   - any other non-PASS (missing evidence, memory reject, invalid sustained summary) -> STOP.
# Overridable for tests: BR, CHECK_PROC, RUN_V0E, SESS_PAUSE + the runner's variables (RUN_ROUTE, MEMFLOOR, PROBE_WAIT...).
set -uo pipefail
source ~/v0/v0d_lib.sh
BR=${BR:-$HOME/bench-runs}; CHECK_PROC=${CHECK_PROC:-pgrep -f}
RUN_V0E=${RUN_V0E:-$HOME/v0/run_v0e.sh}
SESS_PAUSE=${SESS_PAUSE:-180}
PH=v0e-A-retry; ST=$BR/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=$BR/v0/$PH
mkdir -p $O $BR/v0/v0d; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
# AW = the D90-admitted A command with -c 32768 (D118), with the patched DSP library first on ADSP_LIBRARY_PATH (D136)
HTPR=${HTPR:-$HOME/v0/htp-retry}; RETRY_SHA=${RETRY_SHA:-aa2ae2a978d95935b763234c1a6cefe27f42c1cf98d67f041c17f13210fedde2}
FARF=${FARF:-$HOME/v0/farf}; JOURNAL=${JOURNAL:-journalctl}
rsha() { [ "$(sha256sum "$HTPR/libggml-htp-v75.so" 2>/dev/null | cut -d' ' -f1)" = "$RETRY_SHA" ] && [ "$(cat "$FARF/llama-server.farf" 2>/dev/null)" = 0x1f ]; }
AW="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$FARF;$HTPR;$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 32768 --cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
$CHECK_PROC '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: NPU stall watchdog not running"; exit 6; }
$CHECK_PROC '^/bin/bash /home/arduino/v0/monitor/health_sampler.sh' > /dev/null || { say "STOP: health sampler not running"; exit 6; }
# loadfail <dir>: a clean load failure (D114, the admission rule's LOADFAIL): the server exited before ready on an NPU
# mapping failure, with passing health and a kernel audit of pass or npu_map only.
loadfail() { grep -q 'SERVER EXITED before ready' $1/run.txt 2>/dev/null && grep -q 'RESULT FAIL: load=4$' $1/run.txt \
  && grep -q 'mapping failed' $1/server.log 2>/dev/null && grep -q '^pass' $1/health-verdict.txt 2>/dev/null \
  && { read -r k _ < $1/kernel-audit.txt; [ "$k" = pass ] || [ "$k" = npu_map ]; } 2>/dev/null; }
# session <label> <workload> <timeout>: baseline -> A session; sets C (class) and LAB (the run's label). Runs in
# this shell (not in a command substitution) so that every STOP exits the driver. A clean load failure (D114): recovery
# (ready wait), then the session once more (its baseline first) as <label>-retry; a second one stops.
session() { local lab=$1 wl=$2 to=$3 wd0 rc f0 try
  for try in 1 2; do LAB=$lab; [ $try = 2 ] && LAB=$lab-retry
    f0=$(nfaults); ready now   # a baseline fault is recorded by ready(), which keeps probing until a PASS (recovery)
    [ "$(nfaults)" = "$f0" ] || { say "V0e A-retry: NOT QUALIFIED (fault in the baseline before $LAB; recovered)"; exit 3; }
    rsha || { say "STOP: $HTPR/libggml-htp-v75.so is not sha256 $RETRY_SHA (or the .farf file is not 0x1f)"; exit 2; }
    say "START $LAB"; wd0=$(wdcount)
    PHASE=$PH timeout -k 60 $to bash $RUN_V0E $LAB $wl -- $AW > /dev/null 2>&1; rc=$?; killall_srv
    rsha || { say "STOP: the patched library or the .farf file changed during $LAB"; exit 2; }
    journal $LAB
    C=$(classify $O/$LAB $rc $wd0); [ "$C" = EVIDENCE ] && loadfail $O/$LAB && C=LOADFAIL
    say "END $LAB: $C | $(grep -h 'RESULT' $O/$LAB/run.txt 2>/dev/null | tail -1)"
    [ "$C" = LOADFAIL ] || return 0
    [ $try = 2 ] && { say "STOP: $lab failed to load twice: V0e A-retry: NOT QUALIFIED (load)"; exit 3; }
    say "LOADFAIL $LAB: recovery, then $lab again (D114 rule)"
    f0=$(nfaults); ready wait
    [ "$(nfaults)" = "$f0" ] || { say "V0e A-retry: NOT QUALIFIED (fault in the recovery after $LAB)"; exit 3; }
  done; }
# journal <label>: the server's journal lines (FastRPC + DSP) to <run dir>/fastrpc-journal.txt; retried peek errors
# counted (a repeat, "(N in a row)" with N > 1, is flagged for the owner).
journal() { local spid n r; spid=$(grep -oE 'server pid [0-9]+' $O/$1/run.txt 2>/dev/null | head -1 | cut -d' ' -f3)
  [ -n "$spid" ] && $JOURNAL _PID=$spid --no-pager -q -o short-iso > $O/$1/fastrpc-journal.txt 2>&1
  n=$(grep -c 'retrying' $O/$1/fastrpc-journal.txt 2>/dev/null); r=$(grep -oE '\(([0-9]+) in a row' $O/$1/fastrpc-journal.txt 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
  say "DSP $1: retried peek errors ${n:-0}, longest run ${r:-0}"; [ "${r:-0}" -gt 1 ] && say "FLAG $1: repeated peek errors (${r} in a row), for the owner"; return 0; }
memcheck() { if python3 $MEMFLOOR --admit 7942 $O/$1 > $O/$1/memfloor-admit.txt 2>&1; then say "MEM $1: $(tail -1 $O/$1/memfloor-admit.txt)"
  else say "STOP: MEM $1: $(tail -1 $O/$1/memfloor-admit.txt)"; say "V0e A-retry: NOT QUALIFIED (memory)"; exit 3; fi; }
onfault() { fault $1 $2; ready wait; say "V0e A-retry: NOT QUALIFIED (fault $2 in $1)"; exit 3; }
say "V0e A-retry start (pid $$), window 32768, patched DSP library, no root"
s1ok=1
session v0e-A-retry-S1 $HOME/v0/v0e_s1.sh 7200
case $C in
  PASS) memcheck $LAB;;
  HANG|DEVFAULT) onfault $LAB $C;;
  *) if grep -q 'RESULT FAIL: workload=[0-9]*$' $O/$LAB/run.txt && [ "$(head -1 $O/$LAB/kernel-audit.txt | cut -d' ' -f1)" = pass ]; then
       s1ok=0; say "S1 FAIL (items: $(grep -c 'rc=[1-9]' $O/$LAB/items.txt) failed; clean session): A not qualified; S2 runs for evidence"
       memcheck $LAB
     else say "STOP: $LAB $C"; exit 2; fi;;
esac
sleep $SESS_PAUSE
session v0e-A-retry-S2 $HOME/v0/v0e_sustained.sh 9000
case $C in
  PASS) memcheck $LAB;;
  HANG|DEVFAULT) onfault $LAB $C;;
  *) say "STOP: $LAB $C"; say "V0e A-retry: NOT QUALIFIED (S2 $C)"; exit 2;;
esac
# D117: no QUALIFIED without the sustained report (first 3 vs last 3 cycles); a >10 % decline is a flag for the owner
sline=$(tail -1 $O/$LAB/sustained-summary.txt 2>/dev/null)
case $sline in "RESULT summary: VALID"*) say "S2 $sline";;
  *) say "STOP: S2 sustained summary missing or not VALID: ${sline:-none}"; say "V0e A-retry: NOT QUALIFIED (S2 summary)"; exit 2;; esac
if [ $s1ok = 1 ]; then say "V0e A-retry: QUALIFIED at window 32768 (S1 and S2 PASS, faults $(nfaults))"; exit 0
else say "V0e A-retry: NOT QUALIFIED (S1 items failed; S2 PASS)"; exit 1; fi
