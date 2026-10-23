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
# the suite: one arena per call, one server log per start; \$M/scen selects a defect
cat > $T/suite/run_model.sh <<EOF
#!/bin/bash
tag=\$1; step=\$STEPS; echo "\$tag \$step \$*" >> $M/run_model-calls
case \$step in 1) lab=\$tag-a1;; 2) lab=\$tag-a2;; 3) lab=\$tag-a3;; 4s) lab=\$tag-a4-32k;; esac
d=\$BENCH_WORK/arena\${step%s}/\$lab; mkdir -p \$d; scen=\$(cat $M/scen 2>/dev/null)
rec() { echo "\$(date -Is) START pid=\$((RANDOM + 100000 * \$2)) boot=b00b log=\$1" >> "\$V1_LEDGER"; }
log() { printf '0.00.100.000 I srv load_model: loaded\n0.01.000.000 I slot print_timing: prompt eval time = 10 ms\n0.01.001.000 I srv update:  - cache state: 1 prompts, 100.000 MiB\n' > \$1; }
if [ "\$scen" = refused ] && [ \$step = 2 ]; then echo "b9_server: REFUSED: identity: FAILED B9 identity: x" > \$d/server.log; exit 0; fi
log \$d/server.log; rec \$d/server.log 1
if [ "\$scen" = restart ] || [ "\$scen" = omit-restart ]; then sleep 1.2; log \$d/server_r1.log; [ "\$scen" = restart ] && rec \$d/server_r1.log 2; fi
[ "\$scen" = record-no-log ] && rec \$d/server_r9.log 3
[ "\$scen" = devfault ] && [ \$step = 3 ] && printf 'ggml-hex: dspqueue_read failed\nGGML_ABORT\n' >> \$d/server.log
[ "\$scen" = nocache ] && sed -i '/cache state/d' \$d/server.log
[ "\$scen" = stray ] && touch $M/server-up
[ "\$scen" = watchdog ] && [ \$step = 2 ] && echo 1 > $M/wd
sleep 1.2
[ "\$scen" = gate ] && [ \$step = 1 ] && exit 1
[ "\$scen" = rc2 ] && [ \$step = 3 ] && exit 2
exit 0
EOF
chmod +x $M/* $T/suite/run_model.sh
# health samples every 0.5 s (the mocked arenas last ~1.2 s) from 1 min ago to 1 h ahead; \$1 = MemAvailable kB;
# \$2 = a gap (s) cut after now
samples() { mkdir -p $T/mon; python3 -c "import sys,time
now=time.time(); a=int(sys.argv[1]); g=float(sys.argv[2])
for i in range(-120, 7200):
    e=now+i/2
    if not (now < e < now+g): print('{\"epoch\": %.1f, \"MemAvailable_kB\": %d}' % (e, a))" $1 ${2:-0} > $T/mon/health-20261023.jsonl; }
reset() { rm -rf $T/br; rm -f $M/scen $M/j $M/ka $M/wd $M/id-calls $M/id-fail-at $M/server-up $M/no-daemon $M/health-fail \
  $M/probe-fault $M/probes $M/journal-calls $M/run_model-calls; V1=$T/br/v1; samples 9000000; }
go() { ( export BR=$T/br CHECKOUT=$T/checkout V1_REV=${REVX-$REV} MEASURE=$T/measure MEASURE_SHA=$MSHA SUITE=$T/suite \
    LAUNCHER=/l/b9_server.sh B9_CHECK=$M/b9check JOURNAL=$M/journal MEMFLOOR=$MEMF COVERAGE="python3 $HERE/v1_coverage.py" \
    HEALTH_CHECK=$M/health HVERDICT=$M/hverdict DAEMONS="/w/watchdog.sh /w/sampler.sh" LIST_SERVERS=$M/ps \
    VERSION_CMD=$M/version PI_MODELS=$T/models.json MIN_DISK_KB=${DISK-1} REPEATS="${REP-1}" KWAIT_TRIES=1 KWAIT_S=0 \
    V0D_LIB=$M/lib.sh V0D_RUNNER=$M/runner.sh MONITOR_DIR=$T/mon; bash $D ) > $T/out 2>&1; echo $? > $T/rc; }
rc() { cat $T/rc; }; st() { grep -q -- "$1" $V1/status.txt; }

reset; REP="1 2" go
ok "clean batch, two repeats: DONE, 8 arenas, each with STEPS alone and the launcher, window 32768, big 0" \
  '[ $(rc) = 0 ] && st "V1 B9 batch: DONE" && [ $(grep -c . $M/run_model-calls) = 8 ] && grep -q "^b9-q20-htp2-r2 4s b9-q20-htp2-r2 32768 0 /l/b9_server.sh$" $M/run_model-calls'
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
ok "health samples missing over a lifetime stop before the memory verdict" '[ $(rc) = 2 ] && st "memory evidence missing: " && ! st "LIFETIME"'
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
ok "a fault in a baseline probe stops before the ladder" '[ $(rc) = 3 ] && st "a fault in the baseline probes" && [ ! -e $M/run_model-calls ]'
reset; echo 3 > $M/id-fail-at; go
ok "B9 identity lost after an arena stops" '[ $(rc) = 2 ] && st "B9 identity after the arena"'
reset; echo gate > $M/scen; REP="1 2" go
ok "arena 1 failing twice (run_model exit 1) ends that ladder only; the next repeat runs" \
  '[ $(rc) = 0 ] && st "GATE b9-q20-htp2-r1" && ! grep -q "^b9-q20-htp2-r1 2 " $M/run_model-calls && grep -q "^b9-q20-htp2-r2 1 " $M/run_model-calls'
reset; echo rc2 > $M/scen; go
ok "any other run_model exit stops after that arena's checks" '[ $(rc) = 2 ] && st "CHECKS b9-q20-htp2-r1 3" && st "run_model.sh exit 2"'
reset; echo stray > $M/scen; go
ok "a server still up after an arena stops before any checker reads its evidence" \
  '[ $(rc) = 2 ] && st "still running after the arena" && ! grep -q "_PID=[0-9]\{6,\}" $M/journal-calls'

while IFS='|' read -r c why; do
  reset; ( eval "$c"; go ); r=$(rc)
  ok "precondition fails -> stop before any probe or arena: $c" '[ $r = 2 ] && st "$why" && [ ! -e $M/probes ] && [ ! -e $M/run_model-calls ]'
done <<'CASES'
REVX=|V1_REV (the reviewed revision) not set
REVX=HEAD~0^{tree}|is not V1_REV
touch $M/server-up|a llama-server is running
touch $M/no-daemon|not running: /w/watchdog.sh
touch $M/health-fail|launch health: fail
echo 1 > $M/id-fail-at|B9 identity at launch
DISK=999999999999|free disk under
MSHA=0000|measured checkout
CASES
reset; echo '{"providers": {"bench": {"models": [{"id": "local32k", "contextWindow": 65536, "maxTokens": 8192}]}}}' > $T/models.json; go
ok "pi's local32k not as declared stops" '[ $(rc) = 2 ] && st "local32k is not" && [ ! -e $M/probes ]'
echo "$pass passed, $fail failed"; [ $fail = 0 ]
