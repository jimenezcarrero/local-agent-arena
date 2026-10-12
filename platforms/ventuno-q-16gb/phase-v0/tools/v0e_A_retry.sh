#!/bin/bash
# v0e_A_retry.sh [AR|A32] — V0e qualification of A at window 32768 with the patched DSP library (D136, D137, v0e-plan-A-retry.txt).
# D137: runs only after the patched runtime's own admission passed its 16K gate (v0d_admit.sh AR); recovery needs a normal
# runner exit (rc 1) with complete evidence; the DSP journal is fail-closed.
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
# D157: set A32 (v0e-plan-A32.txt) = the same driver and policy with AW at -ngl 32 (output layer on the CPU, D155)
# and --cache-ram 5120 (memfloor --admit 5120), phase v0e-A32, after its own admission (v0d_admit.sh A32, "GATE A32:
# PASS"). Without an argument the set is AR, unchanged.
# D161 (v0e-plan-A32-2.txt): "v0e_A_retry.sh A32 2" is A32's second V0e attempt, phase v0e-A32-2, on the same
# admission. One driver change, declared: the baseline probes (before each session and during recovery) load the
# patched DSP library (ADSP_LIBRARY_PATH=$FARF;$HTPR;<pkg>/lib) instead of the release one; the command is otherwise
# the unchanged NPU health check (-ngl 99, --cache-ram 8192, -c 40960, depth 512), and the library identity is checked
# before every baseline load too (D162: PRE_BASE, so retries and recovery probes are covered). A fault in a
# baseline is still a fault (NOT QUALIFIED); if the identity is lost after a fault, the fault stays recorded and the
# outcome is NOT QUALIFIED (exit 3). Attempt 1 (no second argument)
# and AR are unchanged. S1's cache and compaction items changed for every set from D161 (v0e_window.py, v0e_compact.sh).
# Overridable for tests: BR, CHECK_PROC, RUN_V0E, SESS_PAUSE + the runner's variables (RUN_ROUTE, MEMFLOOR, PROBE_WAIT...).
set -uo pipefail
S=${1:-AR}; case $S in AR) NAME=A-retry; CAP=7942; NGL=99;; A32) NAME=A32; CAP=5120; NGL=32;; *) echo "unknown set $S" >&2; exit 9;; esac
ATT=${2:-1}; case $S/$ATT in */1) ;; A32/2) NAME=A32-2;; *) echo "unknown attempt $ATT for set $S" >&2; exit 9;; esac
source ~/v0/v0d_lib.sh
BR=${BR:-$HOME/bench-runs}; CHECK_PROC=${CHECK_PROC:-pgrep -f}
RUN_V0E=${RUN_V0E:-$HOME/v0/run_v0e.sh}
SESS_PAUSE=${SESS_PAUSE:-180}
PH=v0e-$NAME; ST=$BR/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=$BR/v0/$PH
mkdir -p $O $BR/v0/v0d; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
HTPR=${HTPR:-$HOME/v0/htp-retry}; FARF=${FARF:-$HOME/v0/farf}
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"; [ $ATT = 2 ] && E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$FARF;$HTPR;$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
# AW = the D90-admitted A command with -c 32768 (D118), with the patched DSP library first on ADSP_LIBRARY_PATH (D136);
# A32 (D157): -ngl 32 and --cache-ram 5120
RETRY_SHA=${RETRY_SHA:-aa2ae2a978d95935b763234c1a6cefe27f42c1cf98d67f041c17f13210fedde2}
JOURNAL=${JOURNAL:-journalctl}
rsha() { [ "$(sha256sum "$HTPR/libggml-htp-v75.so" 2>/dev/null | cut -d' ' -f1)" = "$RETRY_SHA" ] && [ "$(cat "$FARF/llama-server.farf" 2>/dev/null)" = 0x1f ]; }
AW="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$FARF;$HTPR;$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 32768 --cache-ram $CAP -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl $NGL --ctx-checkpoints 0"
$CHECK_PROC '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: NPU stall watchdog not running"; exit 6; }
$CHECK_PROC '^/bin/bash /home/arduino/v0/monitor/health_sampler.sh' > /dev/null || { say "STOP: health sampler not running"; exit 6; }
# D137/D138 (Codex reviews of 6f203ab and 12be36a): eligibility first. The LATEST admission attempt of the patched
# runtime (v0d_admit.sh AR; the status file is append-only) must be complete and passing: after its last "admission AR
# start" line, "SET AR: ADMITTED in attempt <n>", "GATE AR: PASS" and "admission AR done rc=0". An older PASS followed
# by a newer failed or unfinished attempt does not count. The gate is then re-applied to the current evidence.
ADMIT_ST=${ADMIT_ST:-$BR/v0/v0d/v0d-admit-$S-status.txt}; ADMIT_O=${ADMIT_O:-$BR/v0/v0d-admit-$S}; GATE=${GATE:-python3 $HOME/v0/admit_gate.py}
ablk=$(awk -v m=" admission $S start " 'index($0, m){b=""} {b=b $0 "\n"} END{printf "%s", b}' "$ADMIT_ST" 2>/dev/null)
aatt=$(printf '%s' "$ablk" | grep -oE "SET $S: ADMITTED in attempt [12]" | tail -1 | grep -oE '[12]$')
{ printf '%s' "$ablk" | grep -q " admission $S start " && [ -n "$aatt" ] && printf '%s' "$ablk" | grep -q " GATE $S: PASS " \
  && printf '%s' "$ablk" | grep -q " admission $S done rc=0 "; } \
  || { say "STOP: the latest patched-runtime admission ($ADMIT_ST) is not complete and passing"; exit 6; }
g=$($GATE $ADMIT_O $S $aatt 2>&1) || { say "STOP: the 16K gate no longer passes on the current admission evidence: $g"; exit 6; }
say "admission $S (attempt $aatt): $g"
# lastres <dir>: the run's last RESULT line, from "RESULT" on
lastres() { grep -oE 'RESULT (PASS|FAIL).*' $1/run.txt 2>/dev/null | tail -1; }
# loadfail <dir>: a clean load failure (D114): the runner exited normally with a completed failure (rc 1; D137: a
# timeout, kill or other status is EVIDENCE and stops), its last RESULT is exactly "RESULT FAIL: load=4", the server
# exited before ready on an NPU mapping failure, health passed and the kernel audit is pass or npu_map only.
loadfail() { [ "$RC" = 1 ] && [ "$(lastres $1)" = "RESULT FAIL: load=4" ] && grep -q 'SERVER EXITED before ready' $1/run.txt \
  && grep -q 'mapping failed' $1/server.log 2>/dev/null && grep -q '^pass' $1/health-verdict.txt 2>/dev/null \
  && { read -r k _ < $1/kernel-audit.txt; [ "$k" = pass ] || [ "$k" = npu_map ]; } 2>/dev/null; }
# s1clean <dir>: S1 items failed on an otherwise clean session (D137): rc 1, last RESULT exactly "RESULT FAIL:
# workload=<n>", health passed, kernel audit pass, and the server was still up at the end of the workload.
s1clean() { [ "$RC" = 1 ] && [[ "$(lastres $1)" =~ ^RESULT\ FAIL:\ workload=[0-9]+$ ]] && grep -q '^pass' $1/health-verdict.txt 2>/dev/null \
  && [ "$(head -1 $1/kernel-audit.txt 2>/dev/null | cut -d' ' -f1)" = pass ] && grep -q 'server still up at the end of the workload' $1/run.txt; }
# session <label> <workload> <timeout>: baseline -> A session; sets C (class) and LAB (the run's label). Runs in
# this shell (not in a command substitution) so that every STOP exits the driver. A clean load failure (D114): recovery
# (ready wait), then the session once more (its baseline first) as <label>-retry; a second one stops.
session() { local lab=$1 wl=$2 to=$3 wd0 f0 try
  for try in 1 2; do LAB=$lab; [ $try = 2 ] && LAB=$lab-retry
    f0=$(nfaults); ready now   # a baseline fault is recorded by ready(), which keeps probing until a PASS (recovery)
    [ "$(nfaults)" = "$f0" ] || { say "V0e $NAME: NOT QUALIFIED (fault in the baseline before $LAB; recovered)"; exit 3; }
    rsha || { say "STOP: $HTPR/libggml-htp-v75.so is not sha256 $RETRY_SHA (or the .farf file is not 0x1f)"; exit 2; }
    say "START $LAB"; wd0=$(wdcount)
    PHASE=$PH timeout -k 60 $to bash $RUN_V0E $LAB $wl -- $AW > /dev/null 2>&1; RC=$?; killall_srv
    C=$(classify $O/$LAB $RC $wd0); [ "$C" = EVIDENCE ] && loadfail $O/$LAB && C=LOADFAIL
    say "END $LAB: $C (runner rc $RC) | $(lastres $O/$LAB)"
    # D162: a fault in the session is recorded before a library stop, so it is not lost
    rsha || { say "STOP: the patched library or the .farf file changed during $LAB"
      case $C in HANG|DEVFAULT) fault $LAB $C; say "V0e $NAME: NOT QUALIFIED (fault $C in $LAB; library identity lost)"; exit 3;; esac; exit 2; }
    # DSP evidence (D137): required. A failed capture stops, except that a real HANG/DEVFAULT keeps its class (the
    # fault path stops anyway, as NOT QUALIFIED).
    # D138: the only exception is a confirmed clean load failure (class LOADFAIL); missing readiness metadata is not one.
    if ! journal $LAB; then
      case $C in LOADFAIL) say "NOTE $LAB: no complete DSP journal for a clean load failure (kept)";;
        HANG|DEVFAULT) say "NOTE $LAB: DSP journal capture failed; the $C stands";;
        *) say "STOP: $LAB: DSP journal evidence missing or incomplete ($(cat $O/$LAB/journal-check.txt 2>/dev/null))"; exit 2;; esac
    fi
    [ "$C" = LOADFAIL ] || return 0
    [ $try = 2 ] && { say "STOP: $lab failed to load twice: V0e $NAME: NOT QUALIFIED (load)"; exit 3; }
    say "LOADFAIL $LAB: recovery, then $lab again (D114 rule)"
    f0=$(nfaults); ready wait
    [ "$(nfaults)" = "$f0" ] || { say "V0e $NAME: NOT QUALIFIED (fault in the recovery after $LAB)"; exit 3; }
  done; }
# journal <label> (D137, fail-closed): the server's journal lines to <run dir>/fastrpc-journal.txt, bound to the run's
# server pid, boot and START..END+60 s window. Returns 1 (reason in journal-check.txt) unless: exactly one server pid,
# the journal command succeeded, the export is non-empty, and it shows the DSP library being opened and DSP-side
# (CDSP0) lines, i.e. the logging cohort was captured. Logged retry events are counted; the patch rate-limits its
# messages (first 8 of a run, then every 1000th), so this is a count of logged events, not of all retries.
journal() { local d=$O/$1 spid boot t0 t1 n r; : > $d/journal-check.txt
  spid=$(grep -oE 'server pid [0-9]+' $d/run.txt 2>/dev/null | cut -d' ' -f3 | sort -u)
  [ "$(printf '%s\n' $spid | grep -c .)" = 1 ] || { echo "server pid missing or ambiguous: '${spid}'" > $d/journal-check.txt; return 1; }
  boot=$(grep -oE ' START .*boot=[^ ]+' $d/run.txt | head -1 | sed 's/.*boot=//'); t0=$(grep -oE '^[^ ]+ START' $d/run.txt | head -1 | cut -d' ' -f1)
  t1=$(grep -oE '^[^ ]+ END' $d/run.txt | tail -1 | cut -d' ' -f1)
  [ -n "$boot" ] && [ -n "$t0" ] && [ -n "$t1" ] || { echo "run.txt lacks boot, START or END" > $d/journal-check.txt; return 1; }
  if ! $JOURNAL _PID=$spid _BOOT_ID=${boot//-/} --since "$(date -d "$t0" '+%Y-%m-%d %H:%M:%S')" --until "$(date -d "$t1 60 seconds" '+%Y-%m-%d %H:%M:%S')" \
       --no-pager -q -o short-iso > $d/fastrpc-journal.txt 2> $d/journal-err.txt; then echo "journal command failed: $(head -c 200 $d/journal-err.txt)" > $d/journal-check.txt; return 1; fi
  [ -s $d/fastrpc-journal.txt ] || { echo "empty journal export" > $d/journal-check.txt; return 1; }
  grep -q 'Successfully opened file libggml-htp-v75.so' $d/fastrpc-journal.txt && grep -q 'CDSP0:' $d/fastrpc-journal.txt \
    || { echo "export lacks the DSP library open line or CDSP0 lines" > $d/journal-check.txt; return 1; }
  n=$(grep -c 'retrying' $d/fastrpc-journal.txt); r=$(grep -oE '\(([0-9]+) in a row' $d/fastrpc-journal.txt | grep -oE '[0-9]+' | sort -n | tail -1)
  echo "ok: pid $spid, $(wc -l < $d/fastrpc-journal.txt) lines" > $d/journal-check.txt
  say "DSP $1: logged retry events ${n:-0}, longest run ${r:-0}"; [ "${r:-0}" -gt 1 ] && say "FLAG $1: repeated peek errors (${r} in a row), for the owner"; return 0; }
# prebase <probe label> (D162, attempt 2): the patched library and .farf identity immediately before each baseline
# load. A mismatch stops; after a recorded fault the outcome stays NOT QUALIFIED (exit 3), the fault history kept.
prebase() { rsha && return 0
  say "STOP: before baseline $1: $HTPR/libggml-htp-v75.so is not sha256 $RETRY_SHA (or the .farf file is not 0x1f)"
  [ "$(nfaults)" -gt 0 ] && { say "V0e $NAME: NOT QUALIFIED (faults recorded: $(nfaults), kept in faults.txt; library identity lost before $1)"; exit 3; }
  exit 2; }
[ $ATT = 2 ] && PRE_BASE=prebase
memcheck() { if python3 $MEMFLOOR --admit $CAP $O/$1 > $O/$1/memfloor-admit.txt 2>&1; then say "MEM $1: $(tail -1 $O/$1/memfloor-admit.txt)"
  else say "STOP: MEM $1: $(tail -1 $O/$1/memfloor-admit.txt)"; say "V0e $NAME: NOT QUALIFIED (memory)"; exit 3; fi; }
onfault() { fault $1 $2; ready wait; say "V0e $NAME: NOT QUALIFIED (fault $2 in $1)"; exit 3; }
say "V0e $NAME start (pid $$), set $S, attempt $ATT, window 32768, -ngl $NGL, --cache-ram $CAP, patched DSP library, baseline library $([ $ATT = 2 ] && echo patched || echo release), no root"
s1ok=1
session $PH-S1 $HOME/v0/v0e_s1.sh 7200
case $C in
  PASS) memcheck $LAB;;
  HANG|DEVFAULT) onfault $LAB $C;;
  *) if s1clean $O/$LAB; then
       s1ok=0; say "S1 FAIL (items: $(grep -c 'rc=[1-9]' $O/$LAB/items.txt) failed; clean session): $NAME not qualified; S2 runs for evidence"
       memcheck $LAB
     else say "STOP: $LAB $C"; exit 2; fi;;
esac
sleep $SESS_PAUSE
session $PH-S2 $HOME/v0/v0e_sustained.sh 9000
case $C in
  PASS) memcheck $LAB;;
  HANG|DEVFAULT) onfault $LAB $C;;
  *) say "STOP: $LAB $C"; say "V0e $NAME: NOT QUALIFIED (S2 $C)"; exit 2;;
esac
# D117: no QUALIFIED without the sustained report (first 3 vs last 3 cycles); a >10 % decline is a flag for the owner
sline=$(tail -1 $O/$LAB/sustained-summary.txt 2>/dev/null)
case $sline in "RESULT summary: VALID"*) say "S2 $sline";;
  *) say "STOP: S2 sustained summary missing or not VALID: ${sline:-none}"; say "V0e $NAME: NOT QUALIFIED (S2 summary)"; exit 2;; esac
if [ $s1ok = 1 ]; then say "V0e $NAME: QUALIFIED at window 32768 (S1 and S2 PASS, faults $(nfaults))"; exit 0
else say "V0e $NAME: NOT QUALIFIED (S1 items failed; S2 PASS)"; exit 1; fi
