#!/bin/bash
# v1_batch.sh <b4|a32> (v1-plan-4B.txt sections 4.2, D187): V1 on B4 or A32-5, the suite ladder at 32768, repeats 1-3,
# run from a checkout of the reviewed revision (V1_REV, required; never the working clone: OPERATING rule 13).
# v1_b9_batch.sh (v1-plan-B9.txt, D185) with the configuration from a table: tag stem, launcher, identity command,
# BENCH_WORK, the version command and its build, and whether the DSP library has a retry path. B9's driver is kept as
# it ran (D186).
#   Preconditions once: the checkout at V1_REV and clean; no llama-server; watchdog and health sampler running; health
#   check pass (no package drift); measured checkout 7badb21 clean; the configuration's identity; disk >= 10 GB; pi's
#   local32k as declared; the sampling audit for the model present ($V1/sampling-audit.txt, made in the launch checks);
#   the version line of the binary the launcher execs, recorded with no server up and naming the configuration's build
#   ($V1/version.txt, for the launcher's --version).
#   Per repeat r: the V0e baseline probe (A32-5's: campaign package, patched library, NPU health; its identity before
#   every load, PRE_BASE; its journal captured fail-closed), then each arena alone: STEPS=<step> run_model.sh
#   <stem>-r<r> 32768 0 <launcher>, steps 1 2 3 4s; run_model.sh exit 1 at step 1 is arena 1's gate (failed twice):
#   the ladder ends there, as the suite's would.
#   After every arena, no server up: watchdog count, health verdict over the arena, the configuration's identity, the
#   lifetime ledger matched one-to-one with the arena's server logs (server.log, server_r<n>.log), and per lifetime (its
#   own run dir under $V1/lifetimes): DSP journal (V0e's journal(): PID and boot bound, command ok, non-empty, library
#   open and CDSP0 lines), kernel audit, the server log's device-fault lines (V0e's DEVFAULT), coverage
#   (v1_coverage.py), then memfloor --admit 5120.
#   DSP retry lines: A32-5's patched library logs them as B9's does (a run longer than 1 is a fault); B4's library has
#   no retry path, so a retry line in a B4 lifetime stops the batch (an identity question). Baseline probes run the
#   campaign's patched library for both and keep its rule.
#   Faults (exit 3): a watchdog kill, a kernel-audit fault (OOM kills included), a server-log device fault, a fault in
#   a baseline probe, a logged retry run longer than 1. STOP (exit 2): any missing or incomplete evidence, a refused
#   start, a memory REJECT, a failed check, an arena without its terminal RESULT and env.txt. Either ends the batch
#   before the next arena; nothing is deleted or rerun.
# Overridable for tests: BR, V1, CHECKOUT, MEASURE_SHA, V0D_LIB, V0D_RUNNER, SUITE, LAUNCHER, ID_CHECK, JOURNAL, MEMFLOOR,
#   COVERAGE, HEALTH_CHECK, HVERDICT, DAEMONS, LIST_SERVERS, VDIR, VERSION_CMD, MEASURE, PI_MODELS, MIN_DISK_KB, REPEATS,
#   KWAIT_TRIES, KWAIT_S, plus the runner's variables.
set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
CFG=${1:-}
case $CFG in
  b4) NAME=B4; STEM=b4-q20-htp1; LNAME=b4_server.sh; IDC=b4_identity_check.sh; RETRY=no; BUILD=ff5a2337
      VDIR=${VDIR:-$HOME/npu-dev/pkg-unpatched-ff5a2337/pkg-unpatched-ff5a2337};;
  a32) NAME=A32-5; STEM=nh4-q40-a32; LNAME=a32_server.sh; IDC=a32_identity_check.sh; RETRY=yes; BUILD=836d57176
      VDIR=${VDIR:-$HOME/v0/hexpkg/pkg-linux};;
  *) echo "v1_batch.sh: unknown configuration '$CFG' (b4 or a32)" >&2; exit 2;;
esac
BR=${BR:-$HOME/bench-runs}; V1=${V1:-$BR/v1-$CFG}; ST=$V1/status.txt; LEDGER=$V1/ledger.txt; LT=$V1/lifetimes
SUITE=${SUITE:-$(readlink -f "$HERE/../../../../suite")}; LAUNCHER=${LAUNCHER:-$HERE/$LNAME}
ID_CHECK=${ID_CHECK:-/bin/bash $HOME/v0/$IDC}; JOURNAL=${JOURNAL:-journalctl}
MEMFLOOR=${MEMFLOOR:-$HOME/v0/memfloor.py}; COVERAGE=${COVERAGE:-python3 $HERE/v1_coverage.py}
HEALTH_CHECK=${HEALTH_CHECK:-python3 $HOME/v0/monitor/health_check.py}; HVERDICT=${HVERDICT:-python3 $HOME/v0/health_verdict.py}
DAEMONS=${DAEMONS:-/home/arduino/v0/npu_stall_watchdog.sh /home/arduino/v0/monitor/health_sampler.sh}
LIST_SERVERS=${LIST_SERVERS:-ps -eo pid,args}; MEASURE=${MEASURE:-$HOME/v0/measure}; CHECKOUT=${CHECKOUT:-$HERE}
MEASURE_SHA=${MEASURE_SHA:-7badb21a23384379e208d56defab9b0781c5e457}; PI_MODELS=${PI_MODELS:-$HOME/.pi/agent/models.json}
# the version of the binary this configuration's launcher execs (review of 070d6b1: B9's driver fixed it to ff5a2337)
VERSION_CMD=${VERSION_CMD:-env LD_LIBRARY_PATH=$VDIR/lib $VDIR/bin/llama-server --version}
MIN_DISK_KB=${MIN_DISK_KB:-10485760}; REPEATS=${REPEATS:-1 2 3}; KWAIT_TRIES=${KWAIT_TRIES:-15}; KWAIT_S=${KWAIT_S:-10}
CAP=5120; WIN=32768
mkdir -p "$V1" "$LT"; say() { echo "$(date -Is) $*" | tee -a "$ST"; sync; }
stop() { say "STOP: $*"; say "V1 $NAME batch: STOPPED (evidence)"; exit 2; }
faultstop() { say "FAULT: $*"; say "V1 $NAME batch: STOPPED (fault)"; exit 3; }
# The process list is evidence too (Codex review of c858ec1): a failed or empty listing stops, never reads as "none".
# listsrv sets SRVS (llama-server PIDs) in this shell; noserver <what> is true when the listing succeeded with none.
listsrv() { local o; o=$($LIST_SERVERS) && [ -n "$o" ] || return 1; SRVS=$(printf '%s\n' "$o" | awk '$2 ~ /\/llama-server$/ {print $1}'); }
noserver() { listsrv || stop "$1: the process list failed"; [ -z "$SRVS" ]; }
killall_srv() { local pid; listsrv || stop "the process list failed (server cleanup)"; for pid in $SRVS; do kill -KILL $pid; done; sleep 5; }
daemon_up() { local o; o=$($LIST_SERVERS) && [ -n "$o" ] || return 1; printf '%s\n' "$o" | awk -v s="$1" '$2=="/bin/bash" && $3==s {f=1} END{exit !f}'; }
# gitrev <repo> <rev>: the commit id, only from a successful command; gitclean <repo>: a successful, empty status
gitrev() { local c; c=$(git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null) && [ -n "$c" ] && echo "$c"; }
gitclean() { local o; o=$(git -C "$1" status --porcelain 2>/dev/null) && [ -z "$o" ]; }

# The V0e baseline probe (v0e_A_retry.sh at LV 5), unchanged: campaign package 836d57176, NeoHorse pure Q4_0, the
# campaign's patched library first on ADSP_LIBRARY_PATH, -ngl 99, depth 512; its identity before every load.
PH=v1-$CFG-probes; O=$BR/v0/$PH; mkdir -p "$O"
P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; HTPR=${HTPR:-$HOME/v0/htp-retry}; FARF=${FARF:-$HOME/v0/farf}
BASE="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$FARF;$HTPR;$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
RETRY_SHA=${RETRY_SHA:-aa2ae2a978d95935b763234c1a6cefe27f42c1cf98d67f041c17f13210fedde2}
PKGID=${PKGID:-python3 $HOME/v0/pkg_identity.py}; PKGMAN=${PKGMAN:-$HOME/v0/pkg-identity-836d57176.txt}
prebase() { [ "$(sha256sum "$HTPR/libggml-htp-v75.so" 2>/dev/null | cut -d' ' -f1)" = "$RETRY_SHA" ] && [ "$(cat "$FARF/llama-server.farf" 2>/dev/null)" = 0x1f ] \
    || stop "before baseline $1: the campaign's patched library or .farf is not as declared"
  $PKGID check "$PKGMAN" "$P" > "$O/pkg-identity-last.txt" 2>&1 || stop "before baseline $1: the campaign package differs ($(tail -1 "$O/pkg-identity-last.txt"))"; }
PRE_BASE=prebase; PROBE_STOP=
source "${V0D_LIB:-$HOME/v0/v0d_lib.sh}"; source "${V0D_RUNNER:-$HOME/v0/v0d_runner.sh}"

# jcheck <run dir> <what>: V0e's journal() (D137) for one server: run.txt gives exactly one server pid, the boot (START
# boot=) and the window (START .. END + 60 s). Prints "<logged retry events> <longest run>"; returns 1, the reason in
# <dir>/journal-check.txt, on an ambiguous pid, a failed command, an empty export or one without the DSP library
# open line and CDSP0 lines. The retry message is rate-limited: the count is of logged events, not of all retries.
jcheck() { local d=$1 spid boot t0 t1 n r; : > "$d/journal-check.txt"
  spid=$(grep -oE 'server pid [0-9]+' "$d/run.txt" 2>/dev/null | cut -d' ' -f3 | sort -u)
  [ "$(printf '%s\n' $spid | grep -c .)" = 1 ] || { echo "server pid missing or ambiguous: '${spid}'" > "$d/journal-check.txt"; return 1; }
  boot=$(grep -oE ' START .*boot=[^ ]+' "$d/run.txt" | head -1 | sed 's/.*boot=//'); t0=$(grep -oE '^[^ ]+ START' "$d/run.txt" | head -1 | cut -d' ' -f1)
  t1=$(grep -oE '^[^ ]+ END' "$d/run.txt" | tail -1 | cut -d' ' -f1)
  [ -n "$boot" ] && [ -n "$t0" ] && [ -n "$t1" ] || { echo "run.txt lacks boot, START or END" > "$d/journal-check.txt"; return 1; }
  if ! $JOURNAL _PID=$spid _BOOT_ID=${boot//-/} --since "$(date -d "$t0" '+%Y-%m-%d %H:%M:%S')" --until "$(date -d "$t1 60 seconds" '+%Y-%m-%d %H:%M:%S')" \
       --no-pager -q -o short-iso > "$d/fastrpc-journal.txt" 2> "$d/journal-err.txt"; then echo "journal command failed: $(head -c 200 "$d/journal-err.txt")" > "$d/journal-check.txt"; return 1; fi
  [ -s "$d/fastrpc-journal.txt" ] || { echo "empty journal export" > "$d/journal-check.txt"; return 1; }
  grep -q 'Successfully opened file libggml-htp-v75.so' "$d/fastrpc-journal.txt" && grep -q 'CDSP0:' "$d/fastrpc-journal.txt" \
    || { echo "export lacks the DSP library open line or CDSP0 lines" > "$d/journal-check.txt"; return 1; }
  n=$(grep -c 'retrying' "$d/fastrpc-journal.txt"); r=$(grep -oE '\(([0-9]+) in a row' "$d/fastrpc-journal.txt" | grep -oE '[0-9]+' | sort -n | tail -1)
  echo "ok: pid $spid, $(wc -l < "$d/fastrpc-journal.txt") lines" > "$d/journal-check.txt"; echo "${n:-0} ${r:-0}"; }
# dsp <run dir> <what> [lifetime]: jcheck, then the policy: missing evidence stops, a logged run longer than 1 is a fault;
# in a lifetime of a configuration whose library has no retry path (B4), any retry line stops (an identity question)
dsp() { local c; c=$(jcheck "$1") || stop "$2: DSP journal evidence missing or incomplete ($(cat "$1/journal-check.txt"))"
  say "DSP $2: logged retry events ${c% *}, longest run ${c#* }"
  # first (review of b0cec52): retry lines in a B4 lifetime are an identity question, whatever their streak
  [ "${3:-}" != lifetime ] || [ $RETRY = yes ] || [ "${c% *}" = 0 ] || stop "$2: retry lines from a library without a retry path ($NAME): not the declared library"
  [ "${c#* }" -le 1 ] || faultstop "$2: repeated peek errors (${c#* } in a row)"; }
# kaudit <run dir> <what>: the kernel audit once the health samples hold a good kernel read after END (exit 3 = not yet)
kaudit() { local i krc=3
  for i in $(seq 1 "$KWAIT_TRIES"); do $KAUDIT "$1" > "$1/kernel-audit.txt" 2>&1; krc=$?; [ $krc = 3 ] || break; sleep "$KWAIT_S"; done
  case $krc in 0) [ "$(head -1 "$1/kernel-audit.txt" | cut -d' ' -f1)" = pass ] || stop "$2: kernel audit $(head -1 "$1/kernel-audit.txt")";;
    1) faultstop "$2: kernel audit $(head -1 "$1/kernel-audit.txt")";; *) stop "$2: kernel audit $(head -1 "$1/kernel-audit.txt")";; esac; }

# ---- preconditions ----
[ -n "${V1_REV:-}" ] || stop "V1_REV (the reviewed revision) not set"
{ h=$(gitrev "$CHECKOUT" HEAD) && w=$(gitrev "$CHECKOUT" "$V1_REV") && [ "$h" = "$w" ] && gitclean "$CHECKOUT"; } \
  || stop "the checkout running this driver ($CHECKOUT) is not a readable repository at V1_REV $V1_REV, or not clean"
noserver launch || stop "a llama-server is running"
for d in $DAEMONS; do daemon_up "$d" || stop "not running: $d"; done
$HEALTH_CHECK 10 > "$V1/health-launch.txt" 2>&1; hc=$?; hv=$($HVERDICT "$V1/health-launch.txt" $hc) || stop "launch health: $hv"
{ h=$(gitrev "$MEASURE" HEAD) && [ "$h" = "$MEASURE_SHA" ] && gitclean "$MEASURE"; } \
  || stop "measured checkout $MEASURE is not 7badb21 clean"
idl=$($ID_CHECK 2>&1) || stop "$NAME identity at launch: $(echo "$idl" | tail -1)"
[ "$(df -Pk "$HOME" | awk 'NR==2{print $4}')" -ge "$MIN_DISK_KB" ] || stop "free disk under $MIN_DISK_KB kB"
python3 -c "import json,sys
m=[x for p in json.load(open(sys.argv[1]))['providers'].values() for x in p['models'] if x['id']=='local32k']
sys.exit(0 if len(m)==1 and m[0]['contextWindow']==32768 and m[0]['maxTokens']==8192 else 1)" "$PI_MODELS" 2>/dev/null \
  || stop "pi's local32k is not contextWindow 32768, maxTokens 8192 in $PI_MODELS"
grep -q 'embedded sampling' "$V1/sampling-audit.txt" 2>/dev/null || stop "no sampling audit for the model in $V1/sampling-audit.txt (OPERATING rule 6)"
noserver "before the version call" || stop "a llama-server is running before the version call"
$VERSION_CMD 2>&1 | grep -m1 version > "$V1/version.txt"; [ -s "$V1/version.txt" ] || stop "no version line from the pinned binary"
noserver "after the version call" || stop "a llama-server is running after the version call"
grep -q "$BUILD" "$V1/version.txt" || stop "the version line does not name $NAME's build $BUILD: $(cat "$V1/version.txt")"
say "V1 $NAME batch start (pid $$), revision $V1_REV, window $WIN, repeats $REPEATS; $(echo "$idl" | tail -1); health $hv; version $(cat "$V1/version.txt")"

# ---- one arena's evidence (section 4.3, 4.4) ----
# arena_checks <tag> <step> <t_start> <t_end> <wd0>
arena_checks() { local tag=$1 step=$2 ta=$3 tb=$4 wd0=$5 labs lab logs recs n i rec t0 t1 pid boot lg dir cov mf hc hv x
  noserver "$tag $step" || { killall_srv; stop "$tag $step: a llama-server was still running after the arena (killed)"; }
  [ "$(wdcount)" = "$wd0" ] || faultstop "$tag $step: the NPU stall watchdog fired"
  case $step in 1) labs="$tag-a1 $tag-a1-retry";; 2) labs="$tag-a2";; 3) labs="$tag-a3";; 4s) labs="$tag-a4-32k";; esac
  logs=$(for lab in $labs; do for x in "$V1"/*/"$lab"/server.log "$V1"/*/"$lab"/server_r*.log; do [ -e "$x" ] && readlink -f "$x"; done; done | sort)
  [ -n "$logs" ] || stop "$tag $step: no server log in the arena's run directories"
  x=$(grep -l "${LNAME%.sh}: REFUSED" $logs 2>/dev/null | head -1); [ -z "$x" ] || stop "$tag $step: a start was refused: $(grep -m1 "${LNAME%.sh}: REFUSED" "$x")"
  recs=$(awk -v a=" ARENA $tag $step START" -v b=" ARENA $tag $step END" 'index($0,a){f=1; next} index($0,b){f=0} f && / START pid=/' "$LEDGER")
  [ "$(printf '%s\n' "$recs" | grep -oE 'log=.*' | sed 's/^log=//' | xargs -r -n1 readlink -f | sort)" = "$logs" ] \
    || stop "$tag $step: the ledger's server starts do not match the arena's server logs one-to-one (an omitted restart, or a record without a log)"
  [ "$(printf '%s\n' "$recs" | grep -oE 'pid=[0-9]+' | sort | uniq -d | wc -l)" = 0 ] || stop "$tag $step: a server PID appears twice in the ledger"
  # health over the arena: the checker's own floor (1.5 GiB) and alerts; it does not stand in for the admission rule
  $HEALTH_CHECK $(( (tb - ta) / 60 + 3 )) > "$V1/checks-$tag-$step-health.txt" 2>&1; hc=$?
  hv=$($HVERDICT "$V1/checks-$tag-$step-health.txt" $hc) || stop "$tag $step: health $hv"
  n=$(printf '%s\n' "$recs" | grep -c .)
  for i in $(seq 1 "$n"); do rec=$(printf '%s\n' "$recs" | sed -n "${i}p")
    t0=${rec%% *}; pid=$(echo "$rec" | grep -oE 'pid=[0-9]+' | cut -d= -f2); boot=$(echo "$rec" | grep -oE 'boot=[^ ]+' | cut -d= -f2); lg=${rec#*log=}
    t1=$(printf '%s\n' "$recs" | sed -n "$((i + 1))p" | cut -d' ' -f1); [ -n "$t1" ] || t1=$(date -d "@$tb" -Is)
    dir=$LT/$tag-$step-$i; mkdir -p "$dir"; ln -sfn "$lg" "$dir/server.log"
    printf '%s START label=%s boot=%s\n%s server pid %s\n%s END\n' "$t0" "$tag-$step-$i" "$boot" "$t0" "$pid" "$t1" > "$dir/run.txt"
    dsp "$dir" "$tag-$step-$i" lifetime
    kaudit "$dir" "$tag-$step-$i"
    if grep -qE 'ggml-hex: [a-z_]+ failed' "$dir/server.log" && grep -qE 'ggml_abort|GGML_ABORT|terminate called' "$dir/server.log"; then
      faultstop "$tag-$step-$i: device fault in the server log"; fi
    cov=$($COVERAGE "$dir" 2>&1) || stop "$tag-$step-$i: memory evidence $cov"
    mf=$(python3 "$MEMFLOOR" --admit $CAP "$dir" 2>&1); x=$?; echo "$mf" > "$dir/memfloor-admit.txt"
    { [ $x = 0 ] && [ "${mf:0:5}" = ADMIT ]; } || stop "MEM $tag-$step-$i: $(echo "$mf" | tail -1)"
    say "LIFETIME $tag-$step-$i: pid $pid, $cov; $(echo "$mf" | tail -1)"
  done
  idl=$($ID_CHECK 2>&1) || stop "$tag $step: $NAME identity after the arena: $(echo "$idl" | tail -1)"
  say "CHECKS $tag $step: $n server lifetime(s), health $hv, identity ok"; }

# ---- one arena's results (Codex review of c858ec1): run_model.sh returns 0 whatever arenas 2-4 did, so each attempted
# label needs exactly one terminal RESULT line of its arena's form in $V1/results.txt (SERVER_FAILED stops) and its
# env.txt (the suite's manifest: version line, the launcher as server command). A model or test failure is a score.
# needres <label> <arena number>; passres <label>: that RESULT is a pass by run_model.sh's own rule
# RESFORM[n]: arena n's complete RESULT fields after "pimodel=local32k ", as suite/arena<n>.sh writes them (Codex review
# of 7e3c353): every field present, in order, each with its allowed values; FAIL, MODIFIED!, a timeout's pi_rc and any
# turns_passed out of 11 are scores and accepted, a missing, truncated or malformed field is not.
PWR='avg_power=[0-9.]+mW energy=[0-9.]+J power_src=[a-z-]+'; GRD='guard=(INTACT|MODIFIED!)'
declare -A RESFORM=(
  [1]="pytest=(PASS|FAIL) $GRD time=[0-9]+s pi_rc=[0-9]+ $PWR"
  [2]="pytest=(PASS|FAIL) $GRD time=[0-9]+s pi_rc=[0-9]+ $PWR"
  [3]="turns_passed=([0-9]|1[01])/11 server_restarts=[0-9]+ $GRD total=[0-9]+s $PWR"
  [4]="pytest=(PASS|FAIL) $GRD anchor_tag=(PASS|FAIL) anchor_naming=(PASS|FAIL) functions_md=(PASS|FAIL) compactions=[0-9]+ server_restarts=[0-9]+ total=[0-9]+s $PWR")
resline() { grep -E "^[^ ]+ RESULT $1: " "$V1/results.txt" 2>/dev/null; }
needres() { local l n e; l=$(resline "$1"); n=$(printf '%s\n' "$l" | grep -c .)
  [ "$n" = 1 ] || stop "$1: $n RESULT lines in results.txt (exactly one required)"
  case "$l" in *": SERVER_FAILED"*) stop "$1: SERVER_FAILED";; esac
  printf '%s\n' "$l" | grep -qE "^[^ ]+ RESULT $1: arena=$2 pimodel=local32k ${RESFORM[$2]}$" || stop "$1: RESULT line incomplete or not of arena $2's form: ${l:0:200}"
  e=$(ls "$V1"/*/"$1"/env.txt 2>/dev/null | head -1)
  [ -n "$e" ] && grep -qE '^llama-server: .*version' "$e" && grep -q "^server_cmd: .*$LNAME " "$e" || stop "$1: env.txt missing or incomplete"; }
passres() { resline "$1" | grep -q "pytest=PASS guard=INTACT"; }
# arena_results <tag> <step> <rc>: returns 0 to go on, 1 for arena 1's genuine gate (two recorded failing attempts,
# run_model.sh exit 1 and its GATE record); anything inconsistent stops
arena_results() { local tag=$1 step=$2 rc=$3
  case $step in
    1) needres $tag-a1 1
       if passres $tag-a1; then [ -z "$(resline $tag-a1-retry)" ] && [ $rc = 0 ] || stop "$tag 1: arena 1 passed but rc $rc or a retry was recorded"; return 0; fi
       needres $tag-a1-retry 1
       if passres $tag-a1-retry; then [ $rc = 0 ] || stop "$tag 1: the retry passed but run_model.sh exit $rc"; return 0; fi
       [ $rc = 1 ] && grep -qE "^[^ ]+ GATE $tag: arena 1 failed twice" "$V1/results.txt" || stop "$tag 1: two failing attempts without run_model.sh's gate (rc $rc)"
       return 1;;
    2) needres $tag-a2 2;; 3) needres $tag-a3 3;; 4s) needres $tag-a4-32k 4;;
  esac
  [ $rc = 0 ] || stop "$tag $step: run_model.sh exit $rc"; return 0; }

# ---- the batch ----
for r in $REPEATS; do tag=$STEM-r$r
  before=$(ls -d "$O"/probe-* 2>/dev/null | sort); f0=$(nfaults)
  ready now
  for x in $(comm -13 <(printf '%s\n' $before) <(ls -d "$O"/probe-* 2>/dev/null | sort)); do dsp "$x" "baseline $(basename "$x")"; done
  [ "$(nfaults)" = "$f0" ] || faultstop "a fault in the baseline probes before $tag (faults.txt in $O)"
  for step in 1 2 3 4s; do
    wd0=$(wdcount); ta=$(date +%s); echo "$(date -Is) ARENA $tag $step START" >> "$LEDGER"; say "START $tag $step"
    STEPS=$step BENCH_WORK=$V1 V1_LEDGER=$LEDGER V1_VERSION=$V1/version.txt bash "$SUITE/run_model.sh" $tag $WIN 0 "$LAUNCHER" \
      >> "$V1/run_model-$tag.txt" 2>&1; rc=$?
    tb=$(date +%s); echo "$(date -Is) ARENA $tag $step END rc=$rc" >> "$LEDGER"; say "END $tag $step: run_model rc $rc"
    arena_checks $tag $step $ta $tb $wd0
    arena_results $tag $step $rc || { say "GATE $tag: arena 1 failed twice; this ladder ends (suite rule)"; break; }
    say "RESULT $tag $step: $(case $step in 1) resline $tag-a1-retry || resline $tag-a1;; 2) resline $tag-a2;; 3) resline $tag-a3;; 4s) resline $tag-a4-32k;; esac | tail -1 | cut -d' ' -f2- | cut -c1-200)"
  done
done
say "V1 $NAME batch: DONE (repeats $REPEATS)"
