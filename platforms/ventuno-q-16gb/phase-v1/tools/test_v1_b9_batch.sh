#!/bin/bash
# test_v1_b9_batch.sh — offline tests of v1_b9_batch.sh (v1-plan-B9.txt section 4.5): mocked suite, probe, journal,
# kernel audit and process list; the real memfloor.py and v1_coverage.py on synthetic health samples. No server, no NPU.
set -u
HERE=$(dirname "$(readlink -f "$0")"); D=$HERE/v1_b9_batch.sh; MEMF=$(readlink -f "$HERE/../../phase-v0/tools/memfloor.py")
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
# B9 identity: fails from call number \$(cat $M/id-fail-at) on
cat > $M/b9check <<EOF
#!/bin/bash
n=\$(( \$(cat $M/id-calls 2>/dev/null || echo 0) + 1 )); echo \$n > $M/id-calls
[ -e $M/id-fail-at ] && [ \$n -ge \$(cat $M/id-fail-at) ] && { echo "FAILED B9 identity: mock"; exit 1; }; echo "OK B9 mock"
EOF
# journal: \$M/j selects ok | fail | empty | nodsp | retry2; every call logged
cat > $M/journal <<EOF
#!/bin/bash
echo "\$*" >> $M/journal-calls; case \$(cat $M/j 2>/dev/null || echo ok) in
  fail) echo "journal broke" >&2; exit 1;; empty) exit 0;; nodsp) echo "t host something";;
  retry2) printf 't Successfully opened file libggml-htp-v75.so\nt CDSP0:[R]: dspqueue_peek failed: 0x0000002f (2 in a row), retrying\n';;
  *) printf 't Successfully opened file libggml-htp-v75.so\nt CDSP0:[R]: line\nt CDSP0:[R]: dspqueue_peek failed: 0x0000002f (1 in a row), retrying\n';; esac
EOF
cat > $M/kaudit <<EOF
#!/bin/bash
v=\$(cat $M/ka 2>/dev/null || echo pass); echo "\$v"; case \$v in pass) exit 0;; fault*) exit 1;; *) exit 2;; esac
EOF
printf '#!/bin/bash\necho "t window=1m samples=6 last=x min_avail=9.0GiB swap_max=0kB "\n' > $M/health
cat > $M/hverdict <<EOF
#!/bin/bash
[ -e $M/health-fail ] && { echo "fail: ALERT mock"; exit 1; }; echo pass
EOF
printf '#!/bin/bash\necho "version: 9999 (ff5a2337)"\n' > $M/version
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
if [ "\$scen" = refused ] && [ \$n = 2 ]; then echo "b9_server: REFUSED: identity: FAILED B9 identity: x" > \$d/server.log; record "RESULT \$label: SERVER_FAILED"; exit 1; fi
log \$d/server.log; rec \$d/server.log 1
if [ "\$scen" = restart ] || [ "\$scen" = omit-restart ]; then sleep 1.2; log \$d/server_r1.log; [ "\$scen" = restart ] && rec \$d/server_r1.log 2; fi
[ "\$scen" = record-no-log ] && rec \$d/server_r9.log 3
[ "\$scen" = devfault ] && [ \$n = 3 ] && printf 'ggml-hex: dspqueue_read failed\nGGML_ABORT\n' >> \$d/server.log
[ "\$scen" = nocache ] && sed -i '/cache state/d' \$d/server.log
[ "\$scen" = stray ] && touch $M/server-up
[ "\$scen" = watchdog ] && [ \$n = 2 ] && echo 1 > $M/wd
{ [ "\$scen" = noenv ] && [ \$n = 3 ]; } || printf 'llama-server: version: 9999 (ff5a2337)\nserver_cmd: %s -c 32768 --host 127.0.0.1 --port 8080\n' "\$bin" > \$d/env.txt
sleep 1.2
[ "\$scen" = noresult ] && [ \$n = 2 ] && exit 17
[ "\$scen" = loadfail ] && [ \$n = 3 ] && { record "RESULT \$label: SERVER_FAILED"; exit 1; }
case \$n in
  1) r="pytest=PASS guard=INTACT"; { [ "\$scen" = gate ] || { [ "\$scen" = retrypass ] && [ "\${label%-retry}" = "\$label" ]; }; } && r="pytest=FAIL guard=INTACT"
     record "RESULT \$label: arena=1 pimodel=\$pim \$r time=100s pi_rc=0";;
  2) record "RESULT \$label: arena=2 pimodel=\$pim pytest=FAIL guard=INTACT time=900s pi_rc=124";;
  3) record "RESULT \$label: arena=3 pimodel=\$pim turns_passed=7/11 server_restarts=0 guard=INTACT total=3000s"
     [ "\$scen" = dup ] && record "RESULT \$label: arena=3 pimodel=\$pim turns_passed=7/11 server_restarts=0 guard=INTACT total=3000s";;
  4) record "RESULT \$label: arena=4 pimodel=\$pim pytest=PASS guard=INTACT anchor_tag=1 anchor_naming=1 functions_md=1";;
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
  $M/probe-fault $M/probes $M/journal-calls $M/arena-calls $M/ps-fail $M/ps-fail-always; V1=$T/br/v1; samples 9000000; }
go() { ( export BR=$T/br CHECKOUT=${COX-$T/checkout} V1_REV=${REVX-$REV} MEASURE=${MX-$T/measure} MEASURE_SHA=$MSHA SUITE=$T/suite \
    LAUNCHER=/l/b9_server.sh B9_CHECK=$M/b9check JOURNAL=$M/journal MEMFLOOR=$MEMF COVERAGE="python3 $HERE/v1_coverage.py" \
    HEALTH_CHECK=$M/health HVERDICT=$M/hverdict DAEMONS="/w/watchdog.sh /w/sampler.sh" LIST_SERVERS=$M/ps \
    VERSION_CMD=$M/version PI_MODELS=$T/models.json MIN_DISK_KB=${DISK-1} REPEATS="${REP-1}" KWAIT_TRIES=1 KWAIT_S=0 \
    V0D_LIB=$M/lib.sh V0D_RUNNER=$M/runner.sh MONITOR_DIR=$T/mon; bash $D ) > $T/out 2>&1; echo $? > $T/rc; }
rc() { cat $T/rc; }; st() { grep -q -- "$1" $V1/status.txt; }

reset; REP="1 2" go
ok "clean batch, two repeats (real run_model.sh): DONE, 8 arenas, each with the launcher and window 32768, results recorded" \
  '[ $(rc) = 0 ] && st "V1 B9 batch: DONE" && [ $(grep -c . $M/arena-calls) = 8 ] && grep -qx "b9-q20-htp2-r2-a4-32k /l/b9_server.sh -c 32768 --host 127.0.0.1 --port 8080" $M/arena-calls && st "RESULT b9-q20-htp2-r1 3: RESULT b9-q20-htp2-r1-a3: arena=3 pimodel=local32k turns_passed=7/11"'
ok "a baseline probe before each repeat, its journal captured (PID and boot bound)" \
  '[ $(grep -c . $M/probes) = 2 ] && grep -q "_PID=4242 _BOOT_ID=b00b" $M/journal-calls && st "DSP baseline probe-"'
ok "every lifetime: DSP counted as logged events, memory ADMIT with coverage" \
  '[ $(grep -c "^.* LIFETIME " $V1/status.txt) = 8 ] && st "logged retry events 1, longest run 1" && grep -q "covered: .*ADMIT b9-q20-htp2-r1-1-1 L_min_kB=" $V1/status.txt'
ok "the pinned version recorded before the batch" 'grep -qx "version: 9999 (ff5a2337)" $V1/version.txt'

reset; echo restart > $M/scen; go
ok "a restart with its record: two lifetimes per arena, both checked" '[ $(rc) = 0 ] && [ -d $V1/lifetimes/b9-q20-htp2-r1-1-2 ] && st "CHECKS b9-q20-htp2-r1 1: 2 server lifetime"'
reset; echo omit-restart > $M/scen; go
ok "a restart log missing from the ledger stops (exit 2), before any lifetime check" '[ $(rc) = 2 ] && st "do not match the arena.s server logs one-to-one" && [ ! -e $M/journal-calls.lifetime ] && ! st LIFETIME'
reset; echo record-no-log > $M/scen; go
ok "a ledger record without a log stops" '[ $(rc) = 2 ] && st "one-to-one"'
reset; echo refused > $M/scen; go
ok "a refused start (identity) stops with its reason" '[ $(rc) = 2 ] && st "a start was refused: b9_server: REFUSED: identity"'

reset; echo fail > $M/j; go
ok "a failed journal command stops (no zero count from absent evidence)" '[ $(rc) = 2 ] && st "DSP journal evidence missing or incomplete (journal command failed" && ! st "logged retry events"'
reset; echo empty > $M/j; go
ok "an empty journal export stops" '[ $(rc) = 2 ] && st "empty journal export"'
reset; echo nodsp > $M/j; go
ok "an export without the DSP library and CDSP0 lines stops" '[ $(rc) = 2 ] && st "lacks the DSP library open line"'
reset; echo retry2 > $M/j; go
ok "a logged retry run of 2 is a fault (exit 3)" '[ $(rc) = 3 ] && st "repeated peek errors (2 in a row)"'

reset; samples 3000000; go
ok "a memory floor violation that passes the 1.5 GiB health floor stops (memfloor REJECT)" '[ $(rc) = 2 ] && st "health pass" && st "STOP: MEM b9-q20-htp2-r1-1-1: REJECT"'
reset; samples 9000000 120; go
ok "health samples missing over a lifetime stop before the memory verdict" '[ $(rc) = 2 ] && st "memory evidence missing: " && ! st "DONE"'
# v1_coverage.py alone on a 5-minute lifetime: a 60 s gap inside it, then none
mkdir -p $T/cov; n=$(date +%s); printf '%s server pid 1\n%s END\n' "$(date -d @$((n + 10)) -Is)" "$(date -d @$((n + 310)) -Is)" > $T/cov/run.txt
echo "0.01.000.000 I x" > $T/cov/server.log
python3 -c "import sys
n=int(sys.argv[1])
for e in range(n, n + 330, 10):
    if not (n + 100 < e < n + 160): print('{\"epoch\": %d, \"MemAvailable_kB\": 9000000}' % e)" $n > $T/mon/health-20261023.jsonl
c=$(MONITOR_DIR=$T/mon python3 $HERE/v1_coverage.py $T/cov); r1=$?
ok "coverage: a 60 s gap inside a lifetime is missing evidence" '[ $r1 = 1 ] && [ "${c:0:31}" = "missing: health sample gap 60 s" ]'
python3 -c "import sys
n=int(sys.argv[1])
for e in range(n, n + 330, 10): print('{\"epoch\": %d, \"MemAvailable_kB\": 9000000}' % e)" $n > $T/mon/health-20261023.jsonl
c=$(MONITOR_DIR=$T/mon python3 $HERE/v1_coverage.py $T/cov); r1=$?
ok "coverage: 10 s samples over the lifetime are covered" '[ $r1 = 0 ] && [ "${c:0:8}" = covered: ]'
rm -rf $T/mon/health-20261023.jsonl $T/cov
reset; echo nocache > $M/scen; go
ok "completed requests without a cache-state line stop" '[ $(rc) = 2 ] && st "no .cache state. line"'

reset; echo "fault 1 (killed process)" > $M/ka; go
ok "a kernel-audit fault (OOM kill) is a fault (exit 3)" '[ $(rc) = 3 ] && st "kernel audit fault"'
reset; echo "unknown 1" > $M/ka; go
ok "an unknown kernel alert stops" '[ $(rc) = 2 ] && st "kernel audit unknown"'
reset; echo watchdog > $M/scen; go
ok "a watchdog kill during an arena is a fault" '[ $(rc) = 3 ] && st "the NPU stall watchdog fired"'
reset; echo devfault > $M/scen; go
ok "a device fault in a server log is a fault" '[ $(rc) = 3 ] && st "device fault in the server log"'
reset; touch $M/probe-fault; go
ok "a fault in a baseline probe stops before the ladder" '[ $(rc) = 3 ] && st "a fault in the baseline probes" && [ ! -e $M/arena-calls ]'
reset; echo 3 > $M/id-fail-at; go
ok "B9 identity lost after an arena stops" '[ $(rc) = 2 ] && st "B9 identity after the arena"'
reset; echo gate > $M/scen; REP="1 2" go
ok "arena 1 failing twice (run_model.sh's own gate) ends that ladder only; the next repeat runs" \
  '[ $(rc) = 0 ] && st "GATE b9-q20-htp2-r1" && grep -q "^b9-q20-htp2-r1-a1-retry " $M/arena-calls && ! grep -q "^b9-q20-htp2-r1-a2 " $M/arena-calls && grep -q "^b9-q20-htp2-r2-a1 " $M/arena-calls'
reset; echo retrypass > $M/scen; go
ok "arena 1 failing once, its retry passing: both attempts checked, the ladder goes on" \
  '[ $(rc) = 0 ] && st "CHECKS b9-q20-htp2-r1 1: 2 server lifetime" && grep -q "^b9-q20-htp2-r1-a2 " $M/arena-calls'
reset; echo noresult > $M/scen; go
ok "an arena exiting without its RESULT (run_model.sh still 0) stops" '[ $(rc) = 2 ] && st "b9-q20-htp2-r1-a2: 0 RESULT lines" && ! grep -q "^b9-q20-htp2-r1-a3 " $M/arena-calls'
reset; echo dup > $M/scen; go
ok "two RESULT lines for one label stop" '[ $(rc) = 2 ] && st "b9-q20-htp2-r1-a3: 2 RESULT lines"'
reset; echo loadfail > $M/scen; go
ok "a SERVER_FAILED arena stops" '[ $(rc) = 2 ] && st "b9-q20-htp2-r1-a3: SERVER_FAILED"'
reset; echo noenv > $M/scen; go
ok "an arena without its env.txt stops" '[ $(rc) = 2 ] && st "b9-q20-htp2-r1-a3: env.txt missing"'
reset; echo stray > $M/scen; touch $M/ps-fail; go
ok "a failing process list after an arena, with a server still present, stops before any checker" \
  '[ $(rc) = 2 ] && st "the process list failed" && ! grep -q "_PID=[0-9]\{6,\}" $M/journal-calls'
reset; echo stray > $M/scen; go
ok "a server still up after an arena stops before any checker reads its evidence" \
  '[ $(rc) = 2 ] && st "still running after the arena" && ! grep -q "_PID=[0-9]\{6,\}" $M/journal-calls'

while IFS='|' read -r c why; do
  reset; ( eval "$c"; go ); r=$(rc)
  ok "precondition fails -> stop before any probe or arena: $c" '[ $r = 2 ] && st "$why" && [ ! -e $M/probes ] && [ ! -e $M/arena-calls ]'
done <<'CASES'
REVX=|V1_REV (the reviewed revision) not set
REVX=HEAD~0^{tree}|not a readable repository at V1_REV HEAD~0
touch $M/server-up|a llama-server is running
touch $M/no-daemon|not running: /w/watchdog.sh
touch $M/health-fail|launch health: fail
echo 1 > $M/id-fail-at|B9 identity at launch
DISK=999999999999|free disk under
MSHA=0000|measured checkout
COX=$T/nonexistent|is not a readable repository at V1_REV
mkdir $T/plain; COX=$T/plain|is not a readable repository at V1_REV
MX=$T/nonexistent|measured checkout
touch $M/ps-fail-always|launch: the process list failed
CASES
reset; echo '{"providers": {"bench": {"models": [{"id": "local32k", "contextWindow": 65536, "maxTokens": 8192}]}}}' > $T/models.json; go
ok "pi's local32k not as declared stops" '[ $(rc) = 2 ] && st "local32k is not" && [ ! -e $M/probes ]'
echo "$pass passed, $fail failed"; [ $fail = 0 ]
