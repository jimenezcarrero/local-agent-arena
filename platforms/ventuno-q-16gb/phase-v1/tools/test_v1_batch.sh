#!/bin/bash
# test_v1_batch.sh — offline tests of v1_batch.sh b4 and a32 (v1-plan-4B.txt section 4.3): test_v1_b9_batch.sh's
# scenarios for each configuration (mocked suite arenas on the real run_model.sh and lib.sh, probe, journal, kernel audit
# and process list; the real memfloor.py and v1_coverage.py on synthetic health samples), plus the configuration rules:
# an unknown configuration, B4's retry rule, the version per configuration with the driver-to-manifest path through the
# real launcher, the sampling audit. No server, no NPU.
set -u
HERE=$(dirname "$(readlink -f "$0")"); D=$HERE/v1_batch.sh; MEMF=$(readlink -f "$HERE/../../phase-v0/tools/memfloor.py")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; tail -3 "$V1/status.txt" 2>/dev/null | sed 's/^/    /'; fi; }
M=$T/mock; mkdir -p $M $T/suite
# checkout and measured checkout: throwaway git repositories
for g in checkout measure; do git init -q $T/$g && git -C $T/$g -c user.email=t@t -c user.name=t commit -q --allow-empty -m x; done
REV=$(git -C $T/checkout rev-parse HEAD); MSHA=$(git -C $T/measure rev-parse HEAD)
cat > $T/models.json <<'EOF'
{"providers": {"bench": {"models": [{"id": "local32k", "contextWindow": 32768, "maxTokens": 8192}]}}}
EOF
# process list: the two daemons, plus a llama-server while $M/server-up exists
cat > $M/ps <<EOF
#!/bin/bash
[ -e $M/ps-fail-always ] && exit 7; [ -e $M/ps-fail ] && [ -e $M/server-up ] && exit 7
echo "  PID COMMAND"; [ -e $M/no-daemon ] || { echo " 11 /bin/bash /w/watchdog.sh"; echo " 12 /bin/bash /w/sampler.sh"; }
[ -e $M/server-up ] && echo " 99999999 /pb/bin/llama-server -m x"; true
EOF
# the configuration's identity: fails from call number \$(cat $M/id-fail-at) on
cat > $M/idcheck <<EOF
#!/bin/bash
n=\$(( \$(cat $M/id-calls 2>/dev/null || echo 0) + 1 )); echo \$n > $M/id-calls
[ -e $M/id-fail-at ] && [ \$n -ge \$(cat $M/id-fail-at) ] && { echo "FAILED identity: mock"; exit 1; }; echo "OK identity mock"
EOF
# journal: \$M/j selects ok | fail | empty | nodsp | retry2; every call logged
cat > $M/journal <<EOF
#!/bin/bash
echo "\$*" >> $M/journal-calls; case \$(cat $M/j 2>/dev/null || echo ok) in
  fail) echo "journal broke" >&2; exit 1;; empty) exit 0;; nodsp) echo "t host something";;
  retry2) printf 't Successfully opened file libggml-htp-v75.so\nt CDSP0:[R]: dspqueue_peek failed: 0x0000002f (2 in a row), retrying\n';;
  retry2life) printf 't Successfully opened file libggml-htp-v75.so\nt CDSP0:[R]: line\n'  # probes clean, lifetimes a run of 2
     echo "\$*" | grep -q _PID=4242 || echo 't CDSP0:[R]: dspqueue_peek failed: 0x0000002f (2 in a row), retrying';;
  *) printf 't Successfully opened file libggml-htp-v75.so\nt CDSP0:[R]: line\n'
     { [ -e $M/retry-ok ] || echo "\$*" | grep -q _PID=4242; } && echo 't CDSP0:[R]: dspqueue_peek failed: 0x0000002f (1 in a row), retrying'; true;; esac
EOF
cat > $M/kaudit <<EOF
#!/bin/bash
v=\$(cat $M/ka 2>/dev/null || echo pass); echo "\$v"; case \$v in pass) exit 0;; fault*) exit 1;; *) exit 2;; esac
EOF
printf '#!/bin/bash\n[ -e %s/srv-at-health ] && touch %s/server-up\necho "t window=1m samples=6 last=x min_avail=9.0GiB swap_max=0kB "\n' $M $M > $M/health
cat > $M/hverdict <<EOF
#!/bin/bash
[ -e $M/health-fail ] && { echo "fail: ALERT mock"; exit 1; }; echo pass
EOF
printf '#!/bin/bash\necho "version: 9999 ($(cat %s/build))"\n' $M > $M/version
# a package directory per configuration for the driver's default version command (env LD_LIBRARY_PATH=<pkg>/lib
# <pkg>/bin/llama-server --version), its binary printing its build
for b in ff5a2337 836d57176; do mkdir -p $M/pkg-$b/lib $M/pkg-$b/bin
  printf '#!/bin/bash\necho "version: 1 (build 1, commit %s)"\n' $b > $M/pkg-$b/bin/llama-server; chmod +x $M/pkg-$b/bin/llama-server; done
cat > $M/lib.sh <<EOF
KAUDIT=$M/kaudit
wdcount() { cat $M/wd 2>/dev/null || echo 0; }
EOF
# the baseline probe: one probe run directory per call (run.txt as run_route.sh writes it); \$M/probe-fault adds a fault
cat > $M/runner.sh <<EOF
nfaults() { local n; n=\$(grep -c . "\$O/faults.txt" 2>/dev/null); echo "\${n:-0}"; }
ready() { local lab=probe-\$(date +%s%N); mkdir -p \$O/\$lab
  printf '%s START label=%s phase=x boot=b00b\n%s server pid 4242\n%s END rc=0\n' "\$(date -Is)" \$lab "\$(date -Is)" "\$(date -Is)" > \$O/\$lab/run.txt
  echo "\$lab" >> $M/probes; [ -e $M/probe-fault ] && echo "\$(date -Is) \$lab HANG" >> \$O/faults.txt; return 0; }
EOF
# the suite: the revision's real run_model.sh and lib.sh, with mock arena scripts (one file, linked as arena1-4.sh):
# one server log per start, the ledger record the launcher would write, env.txt and the RESULT record; \$M/scen
# selects a defect
SUITE_REAL=$(readlink -f "$HERE/../../../../suite"); cp $SUITE_REAL/run_model.sh $SUITE_REAL/lib.sh $T/suite/
cat > $T/suite/arena.mock <<MOCK
#!/bin/bash
n=\$(basename \$0 .sh); n=\${n#arena}; label=\$1; shift; pim=\${PI_MODEL:-}; [ \$n = 4 ] && { pim=\$1; shift; }; bin=\$1
echo "\$label \$*" >> $M/arena-calls
source $T/suite/lib.sh
d=\$BENCH_WORK/arena\$n/\$label; mkdir -p \$d; scen=\$(cat $M/scen 2>/dev/null)
rec() { echo "\$(date -Is) START pid=\$((RANDOM + 100000 * \$2)) boot=b00b log=\$1" >> "\$V1_LEDGER"; }
log() { printf '0.00.100.000 I srv load_model: loaded\n0.01.000.000 I slot print_timing: prompt eval time = 10 ms\n0.01.001.000 I srv update:  - cache state: 1 prompts, 100.000 MiB\n' > \$1; }
if [ "\$scen" = refused ] && [ \$n = 2 ]; then echo "\$(basename \$bin .sh): REFUSED: identity: FAILED identity: x" > \$d/server.log; record "RESULT \$label: SERVER_FAILED"; exit 1; fi
log \$d/server.log; rec \$d/server.log 1
if [ "\$scen" = restart ] || [ "\$scen" = omit-restart ]; then sleep 1.2; log \$d/server_r1.log; [ "\$scen" = restart ] && rec \$d/server_r1.log 2; fi
[ "\$scen" = record-no-log ] && rec \$d/server_r9.log 3
[ "\$scen" = devfault ] && [ \$n = 3 ] && printf 'ggml-hex: dspqueue_read failed\nGGML_ABORT\n' >> \$d/server.log
[ "\$scen" = nocache ] && sed -i '/cache state/d' \$d/server.log
[ "\$scen" = stray ] && touch $M/server-up
[ "\$scen" = watchdog ] && [ \$n = 2 ] && echo 1 > $M/wd
{ [ "\$scen" = noenv ] && [ \$n = 3 ]; } || printf "llama-server: version: 9999 (\$(cat $M/build))\nserver_cmd: %s -c 32768 --host 127.0.0.1 --port 8080\n" "\$bin" > \$d/env.txt
sleep 1.2
[ "\$scen" = noresult ] && [ \$n = 2 ] && exit 17
[ "\$scen" = loadfail ] && [ \$n = 3 ] && { record "RESULT \$label: SERVER_FAILED"; exit 1; }
case \$n in
  1) r="pytest=PASS guard=INTACT"; { [ "\$scen" = gate ] || { [ "\$scen" = retrypass ] && [ "\${label%-retry}" = "\$label" ]; }; } && r="pytest=FAIL guard=INTACT"
     record "RESULT \$label: arena=1 pimodel=\$pim \$r time=100s pi_rc=0 avg_power=0mW energy=0J power_src=none";;
  2) record "RESULT \$label: arena=2 pimodel=\$pim pytest=FAIL guard=INTACT time=900s pi_rc=124 avg_power=0mW energy=0J power_src=none";;
  3) case "\$scen" in prefix) record "RESULT \$label: arena=3 pimodel=\$pim "; exit 0;;
       badturns) record "RESULT \$label: arena=3 pimodel=\$pim turns_passed=12/11 server_restarts=0 guard=INTACT total=3000s avg_power=0mW energy=0J power_src=none"; exit 0;;
       truncated) record "RESULT \$label: arena=3 pimodel=\$pim turns_passed=7/11 server_restarts=0 guard=INTACT total=3000s avg_power=0mW"; exit 0;; esac
     record "RESULT \$label: arena=3 pimodel=\$pim turns_passed=7/11 server_restarts=0 guard=INTACT total=3000s avg_power=0mW energy=0J power_src=none"
     [ "\$scen" = dup ] && record "RESULT \$label: arena=3 pimodel=\$pim turns_passed=7/11 server_restarts=0 guard=INTACT total=3000s avg_power=0mW energy=0J power_src=none";;
  4) record "RESULT \$label: arena=4 pimodel=\$pim pytest=PASS guard=INTACT anchor_tag=PASS anchor_naming=FAIL functions_md=PASS compactions=2 server_restarts=0 total=5000s avg_power=0mW energy=0J power_src=none";;
esac
exit 0
MOCK
for i in 1 2 3 4; do ln -s arena.mock $T/suite/arena$i.sh; done
chmod +x $M/* $T/suite/run_model.sh $T/suite/arena.mock
# health samples every 0.5 s (the mocked arenas last ~1.2 s) from 1 min ago to 1 h ahead; \$1 = MemAvailable kB;
# \$2 = a gap (s) cut after now
samples() { mkdir -p $T/mon; python3 -c "import sys,time
now=time.time(); a=int(sys.argv[1]); g=float(sys.argv[2])
for i in range(-120, 7200):
    e=now+i/2
    if not (now < e < now+g): print('{\"epoch\": %.1f, \"MemAvailable_kB\": %d}' % (e, a))" $1 ${2:-0} > $T/mon/health-20261023.jsonl; }
reset() { rm -rf $T/br; rm -f $M/scen $M/j $M/ka $M/wd $M/id-calls $M/id-fail-at $M/server-up $M/no-daemon $M/health-fail \
  $M/probe-fault $M/probes $M/journal-calls $M/arena-calls $M/ps-fail $M/ps-fail-always $M/retry-ok $M/srv-at-health
  V1=$T/br/v1-$CFG; samples 9000000; echo $BUILD > $M/build; [ $CFG = a32 ] && touch $M/retry-ok
  mkdir -p $V1; printf '# checked x\n## GGUF: m.gguf\n  embedded sampling: none\n' > $V1/sampling-audit.txt
  echo '{"providers": {"bench": {"models": [{"id": "local32k", "contextWindow": 32768, "maxTokens": 8192}]}}}' > $T/models.json; }
go() { ( export BR=$T/br CHECKOUT=${COX-$T/checkout} V1_REV=${REVX-$REV} MEASURE=${MX-$T/measure} MEASURE_SHA=$MSHA SUITE=$T/suite \
    LAUNCHER=/l/$LNAME ID_CHECK=$M/idcheck JOURNAL=$M/journal MEMFLOOR=$MEMF COVERAGE="python3 $HERE/v1_coverage.py" \
    HEALTH_CHECK=$M/health HVERDICT=$M/hverdict DAEMONS="/w/watchdog.sh /w/sampler.sh" LIST_SERVERS=$M/ps \
    VERSION_CMD=${VCMDX-$M/version} VDIR=$M/pkg-${VBUILD-$BUILD} PI_MODELS=$T/models.json MIN_DISK_KB=${DISK-1} REPEATS="${REP-1}" KWAIT_TRIES=1 KWAIT_S=0 \
    V0D_LIB=$M/lib.sh V0D_RUNNER=$M/runner.sh MONITOR_DIR=$T/mon; bash $D ${CFGX-$CFG} ) > $T/out 2>&1; echo $? > $T/rc; }
rc() { cat $T/rc; }; st() { grep -q -- "$1" $V1/status.txt; }

for CFG in b4 a32; do
  case $CFG in b4) NAME=B4; STEM=b4-q20-htp1; LNAME=b4_server.sh; BUILD=ff5a2337; OTHER=836d57176; RL=0;;
    a32) NAME=A32-5; STEM=nh4-q40-a32; LNAME=a32_server.sh; BUILD=836d57176; OTHER=ff5a2337; RL=1;; esac
reset; REP="1 2" go
ok "$CFG: clean batch, two repeats (real run_model.sh): DONE, 8 arenas, each with the launcher and window 32768, results recorded" \
  '[ $(rc) = 0 ] && st "V1 $NAME batch: DONE" && [ $(grep -c . $M/arena-calls) = 8 ] && grep -qx "$STEM-r2-a4-32k /l/$LNAME -c 32768 --host 127.0.0.1 --port 8080" $M/arena-calls && st "RESULT $STEM-r1 3: RESULT $STEM-r1-a3: arena=3 pimodel=local32k turns_passed=7/11" && st "RESULT $STEM-r1 2: RESULT $STEM-r1-a2: arena=2 pimodel=local32k pytest=FAIL guard=INTACT time=900s pi_rc=124"'
ok "$CFG: a baseline probe before each repeat, its journal captured (PID and boot bound)" \
  '[ $(grep -c . $M/probes) = 2 ] && grep -q "_PID=4242 _BOOT_ID=b00b" $M/journal-calls && st "DSP baseline probe-"'
ok "$CFG: every lifetime: DSP counted as logged events, memory ADMIT with coverage" \
  '[ $(grep -c "^.* LIFETIME " $V1/status.txt) = 8 ] && st "logged retry events $RL, longest run $RL" && grep -q "covered: .*ADMIT $STEM-r1-1-1 L_min_kB=" $V1/status.txt'
ok "$CFG: the pinned version recorded before the batch" 'grep -qx "version: 9999 ($BUILD)" $V1/version.txt'

reset; echo restart > $M/scen; go
ok "$CFG: a restart with its record: two lifetimes per arena, both checked" '[ $(rc) = 0 ] && [ -d $V1/lifetimes/$STEM-r1-1-2 ] && st "CHECKS $STEM-r1 1: 2 server lifetime"'
reset; echo omit-restart > $M/scen; go
ok "$CFG: a restart log missing from the ledger stops (exit 2), before any lifetime check" '[ $(rc) = 2 ] && st "do not match the arena.s server logs one-to-one" && [ ! -e $M/journal-calls.lifetime ] && ! st LIFETIME'
reset; echo record-no-log > $M/scen; go
ok "$CFG: a ledger record without a log stops" '[ $(rc) = 2 ] && st "one-to-one"'
reset; echo refused > $M/scen; go
ok "$CFG: a refused start (identity) stops with its reason" '[ $(rc) = 2 ] && st "a start was refused: ${LNAME%.sh}: REFUSED: identity"'

reset; echo fail > $M/j; go
ok "$CFG: a failed journal command stops (no zero count from absent evidence)" '[ $(rc) = 2 ] && st "DSP journal evidence missing or incomplete (journal command failed" && ! st "logged retry events"'
reset; echo empty > $M/j; go
ok "$CFG: an empty journal export stops" '[ $(rc) = 2 ] && st "empty journal export"'
reset; echo nodsp > $M/j; go
ok "$CFG: an export without the DSP library and CDSP0 lines stops" '[ $(rc) = 2 ] && st "lacks the DSP library open line"'
reset; echo retry2 > $M/j; go
ok "$CFG: a logged retry run of 2 is a fault (exit 3)" '[ $(rc) = 3 ] && st "repeated peek errors (2 in a row)"'

reset; samples 3000000; go
ok "$CFG: a memory floor violation that passes the 1.5 GiB health floor stops (memfloor REJECT)" '[ $(rc) = 2 ] && st "health pass" && st "STOP: MEM $STEM-r1-1-1: REJECT"'
reset; samples 9000000 120; go
ok "$CFG: health samples missing over a lifetime stop before the memory verdict" '[ $(rc) = 2 ] && st "memory evidence missing: " && ! st "DONE"'
# v1_coverage.py alone on a 5-minute lifetime: a 60 s gap inside it, then none
mkdir -p $T/cov; n=$(date +%s); printf '%s server pid 1\n%s END\n' "$(date -d @$((n + 10)) -Is)" "$(date -d @$((n + 310)) -Is)" > $T/cov/run.txt
echo "0.01.000.000 I x" > $T/cov/server.log
python3 -c "import sys
n=int(sys.argv[1])
for e in range(n, n + 330, 10):
    if not (n + 100 < e < n + 160): print('{\"epoch\": %d, \"MemAvailable_kB\": 9000000}' % e)" $n > $T/mon/health-20261023.jsonl
c=$(MONITOR_DIR=$T/mon python3 $HERE/v1_coverage.py $T/cov); r1=$?
ok "$CFG: coverage: a 60 s gap inside a lifetime is missing evidence" '[ $r1 = 1 ] && [ "${c:0:31}" = "missing: health sample gap 60 s" ]'
python3 -c "import sys
n=int(sys.argv[1])
for e in range(n, n + 330, 10): print('{\"epoch\": %d, \"MemAvailable_kB\": 9000000}' % e)" $n > $T/mon/health-20261023.jsonl
c=$(MONITOR_DIR=$T/mon python3 $HERE/v1_coverage.py $T/cov); r1=$?
ok "$CFG: coverage: 10 s samples over the lifetime are covered" '[ $r1 = 0 ] && [ "${c:0:8}" = covered: ]'
rm -rf $T/mon/health-20261023.jsonl $T/cov
reset; echo nocache > $M/scen; go
ok "$CFG: completed requests without a cache-state line stop" '[ $(rc) = 2 ] && st "no .cache state. line"'

reset; echo "fault 1 (killed process)" > $M/ka; go
ok "$CFG: a kernel-audit fault (OOM kill) is a fault (exit 3)" '[ $(rc) = 3 ] && st "kernel audit fault"'
reset; echo "unknown 1" > $M/ka; go
ok "$CFG: an unknown kernel alert stops" '[ $(rc) = 2 ] && st "kernel audit unknown"'
reset; echo watchdog > $M/scen; go
ok "$CFG: a watchdog kill during an arena is a fault" '[ $(rc) = 3 ] && st "the NPU stall watchdog fired"'
reset; echo devfault > $M/scen; go
ok "$CFG: a device fault in a server log is a fault" '[ $(rc) = 3 ] && st "device fault in the server log"'
reset; touch $M/probe-fault; go
ok "$CFG: a fault in a baseline probe stops before the ladder" '[ $(rc) = 3 ] && st "a fault in the baseline probes" && [ ! -e $M/arena-calls ]'
reset; echo 3 > $M/id-fail-at; go
ok "$CFG: identity lost after an arena stops" '[ $(rc) = 2 ] && st "identity after the arena"'
reset; echo gate > $M/scen; REP="1 2" go
ok "$CFG: arena 1 failing twice (run_model.sh's own gate) ends that ladder only; the next repeat runs" \
  '[ $(rc) = 0 ] && st "GATE $STEM-r1" && grep -q "^$STEM-r1-a1-retry " $M/arena-calls && ! grep -q "^$STEM-r1-a2 " $M/arena-calls && grep -q "^$STEM-r2-a1 " $M/arena-calls'
reset; echo retrypass > $M/scen; go
ok "$CFG: arena 1 failing once, its retry passing: both attempts checked, the ladder goes on" \
  '[ $(rc) = 0 ] && st "CHECKS $STEM-r1 1: 2 server lifetime" && grep -q "^$STEM-r1-a2 " $M/arena-calls'
reset; echo noresult > $M/scen; go
ok "$CFG: an arena exiting without its RESULT (run_model.sh still 0) stops" '[ $(rc) = 2 ] && st "$STEM-r1-a2: 0 RESULT lines" && ! grep -q "^$STEM-r1-a3 " $M/arena-calls'
for c in prefix badturns truncated; do reset; echo $c > $M/scen; go
  ok "$CFG: an incomplete or malformed arena-3 RESULT ($c) stops" '[ $(rc) = 2 ] && st "$STEM-r1-a3: RESULT line incomplete or not of arena 3" && ! st DONE'; done
reset; echo dup > $M/scen; go
ok "$CFG: two RESULT lines for one label stop" '[ $(rc) = 2 ] && st "$STEM-r1-a3: 2 RESULT lines"'
reset; echo loadfail > $M/scen; go
ok "$CFG: a SERVER_FAILED arena stops" '[ $(rc) = 2 ] && st "$STEM-r1-a3: SERVER_FAILED"'
reset; echo noenv > $M/scen; go
ok "$CFG: an arena without its env.txt stops" '[ $(rc) = 2 ] && st "$STEM-r1-a3: env.txt missing"'
reset; echo stray > $M/scen; touch $M/ps-fail; go
ok "$CFG: a failing process list after an arena, with a server still present, stops before any checker" \
  '[ $(rc) = 2 ] && st "the process list failed" && ! grep -q "_PID=[0-9]\{6,\}" $M/journal-calls'
reset; echo stray > $M/scen; go
ok "$CFG: a server still up after an arena stops before any checker reads its evidence" \
  '[ $(rc) = 2 ] && st "still running after the arena" && ! grep -q "_PID=[0-9]\{6,\}" $M/journal-calls'

while IFS='|' read -r c why; do
  reset; ( eval "$c"; go ); r=$(rc)
  ok "$CFG: precondition fails -> stop before any probe or arena: $c" '[ $r = 2 ] && st "$why" && [ ! -e $M/probes ] && [ ! -e $M/arena-calls ]'
done <<'CASES'
REVX=|V1_REV (the reviewed revision) not set
REVX=HEAD~0^{tree}|not a readable repository at V1_REV HEAD~0
touch $M/server-up|a llama-server is running
touch $M/no-daemon|not running: /w/watchdog.sh
touch $M/health-fail|launch health: fail
echo 1 > $M/id-fail-at|identity at launch
DISK=999999999999|free disk under
MSHA=0000|measured checkout
COX=$T/nonexistent|is not a readable repository at V1_REV
mkdir $T/plain; COX=$T/plain|is not a readable repository at V1_REV
MX=$T/nonexistent|measured checkout
touch $M/ps-fail-always|launch: the process list failed
CASES
reset; echo '{"providers": {"bench": {"models": [{"id": "local32k", "contextWindow": 65536, "maxTokens": 8192}]}}}' > $T/models.json; go
ok "$CFG: pi's local32k not as declared stops" '[ $(rc) = 2 ] && st "local32k is not" && [ ! -e $M/probes ]'

  # ---- the configuration's own rules ----
  reset; CFGX=x9 go
  ok "$CFG: an unknown configuration is refused before anything is written" '[ $(rc) = 2 ] && grep -q "unknown configuration .x9." $T/out && [ ! -e $T/br/v1-x9 ]'
  reset; rm $V1/sampling-audit.txt; go
  ok "$CFG: no sampling audit for the model stops before any probe" '[ $(rc) = 2 ] && st "no sampling audit" && [ ! -e $M/probes ]'
  reset; touch $M/srv-at-health; go
  ok "$CFG: a server up at the version capture is refused (no version recorded)" \
    '[ $(rc) = 2 ] && st "a llama-server is running before the version call" && [ ! -e $V1/version.txt ] && [ ! -e $M/probes ]'
  reset; VBUILD=$OTHER VCMDX= go
  ok "$CFG: a version line naming another build is refused" '[ $(rc) = 2 ] && st "does not name $NAME.s build $BUILD" && [ ! -e $M/probes ]'
  # driver-to-manifest: the driver's default version command on this configuration's package, then the suite's own
  # manifest() through the real launcher with that version file
  reset; VCMDX= go
  ok "$CFG: the default version command records $BUILD's binary" '[ $(rc) = 0 ] && grep -qx "version: 1 (build 1, commit $BUILD)" $V1/version.txt'
  rm -rf $T/mrun; mkdir -p $T/mrun
  ( export BENCH_WORK=$T/bw BENCH_PORT=1 V1_LEDGER=$T/mledger V1_VERSION=$V1/version.txt B4_CHECK=false A32_CHECK=false
    source "$T/suite/lib.sh"; L=$T/mrun; SRV_CMD=("$HERE/$LNAME" -c 32768 --host 127.0.0.1 --port 8080)
    AVAIL0=0; POWER_SRC=none; manifest ) > /dev/null 2>&1
  ok "$CFG: through the real launcher, the suite's env.txt names $BUILD (and no lifetime record)" \
    'grep -qx "llama-server: version: 1 (build 1, commit $BUILD)" $T/mrun/env.txt && [ ! -e $T/mledger ]'
  reset; echo retry2life > $M/j; go
  if [ $CFG = b4 ]; then
    ok "b4: a logged run of 2 in a B4 lifetime is the identity stop (exit 2), not a retry-path fault" \
      '[ $(rc) = 2 ] && st "retry lines from a library without a retry path (B4)" && ! st "FAULT" && st "DSP baseline probe-.*logged retry events 0"'
  else
    ok "a32: a logged run of 2 in an A32-5 lifetime is a fault (exit 3)" '[ $(rc) = 3 ] && st "FAULT: $STEM-r1-1-1: repeated peek errors (2 in a row)"'
  fi
  if [ $CFG = b4 ]; then reset; touch $M/retry-ok; go
    ok "b4: a retry line in a B4 lifetime stops (no retry path in its library)" \
      '[ $(rc) = 2 ] && st "retry lines from a library without a retry path (B4)" && st "DSP baseline probe-"'
  else reset; go
    ok "a32: retry lines in A32-5 lifetimes are counted, not a stop" '[ $(rc) = 0 ] && st "DSP $STEM-r1-1-1: logged retry events 1, longest run 1"'
  fi
  ok "$CFG: the batch wrote only its own BENCH_WORK" '[ "$(ls $T/br)" = "v0
v1-$CFG" ] || [ "$(ls $T/br)" = "v1-$CFG" ]'
done
echo "$pass passed, $fail failed"; [ $fail = 0 ]
