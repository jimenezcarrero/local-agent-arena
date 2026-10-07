#!/bin/bash
# mocked tests for v0d_runner.sh: real classify()/decide(), fake run_route/run_v0c/memfloor driven by a script of outcomes.
# Outcomes per call (one line each in $T/plan): PASS, KFAULT (speed passes, GPU/DSP fault in the kernel window), KUNKNOWN, LOADFAIL, HANG, DEVFAULT, TIMEOUT, NOVERDICT, EXITEVID (timeout + exit line)
fails=0
setup() { T=$(mktemp -d); export T WD_LOG=$T/wd.txt; echo x > $WD_LOG; printf "%s\n" "$@" > $T/plan
cat > $T/fake_run.sh <<'EOS'
#!/bin/bash
lab=$1; [ "$lab" = llama ] && lab=$1; [ -n "${PHASE:-}" ] && lab=$1
o=$O/$lab; mkdir -p $o; out=$(head -1 $T/plan); sed -i 1d $T/plan; echo "$lab $out" >> $T/calls
case $out in
 PASS) echo "t RESULT PASS (speed, health: pass, kernel evidence)" > $o/run.txt; echo pass > $o/health-verdict.txt; : > $o/server.log; exit 0;;
 LOADFAIL) printf "t SERVER EXITED before ready (see server.log)\nt RESULT FAIL: speed=4\n" > $o/run.txt; echo pass > $o/health-verdict.txt; echo "E ggml-hex: HTP0:0 buffer mapping failed : domain_id 3 size 1" > $o/server.log; exit 1;;
 HANG) echo "y NPU-WATCHDOG killed" >> $WD_LOG; echo "t RESULT FAIL: speed=1" > $o/run.txt; echo pass > $o/health-verdict.txt; : > $o/server.log; exit 1;;
 DEVFAULT) echo "t RESULT FAIL: speed=1" > $o/run.txt; echo pass > $o/health-verdict.txt; printf "ggml-hex: dspqueue_read failed: 0x2e\nggml_abort\n" > $o/server.log; exit 1;;
 KFAULT|KUNKNOWN) echo "t RESULT PASS (speed, health: pass, kernel evidence)" > $o/run.txt; echo pass > $o/health-verdict.txt; : > $o/server.log
   [ $out = KFAULT ] && echo "fault fault=23|1" > $o/kaudit || echo "unknown unknown=1|2" > $o/kaudit; exit 0;;
 TIMEOUT) echo "t START" > $o/run.txt; : > $o/server.log; exit 124;;
 NOVERDICT) echo "t RESULT PASS" > $o/run.txt; : > $o/server.log; exit 0;;
 EXITEVID) echo "t SERVER EXITED before ready (see server.log)" > $o/run.txt; : > $o/server.log; exit 124;;
esac
EOS
cat > $T/kaudit.sh <<'K'
#!/bin/bash
v="pass|0"; [ -f "$1/kaudit" ] && v=$(cat "$1/kaudit"); echo "${v%|*}"; exit "${v#*|}"
K
chmod +x $T/fake_run.sh $T/kaudit.sh; export KAUDIT=$T/kaudit.sh; printf 'import sys\nsys.exit(0)\n' > $T/fake_mem.py
export RUN_ROUTE=$T/fake_run.sh RUN_V0C=$T/fake_run.sh MEMFLOOR=$T/fake_mem.py PROBE_WAIT=0 SET_PAUSE=0 FAULT_CAP=${FAULT_CAP:-3}; }
# The fake run_v0c gets "<label> llama 0 -- cmd": its $1 is the label too.
run_case() { local name=$1 want_rc=$2 want_calls=$3 body=$4; shift 4
  setup "$@"; ( PH=t; export O=$T/out; mkdir -p $O; BASE=base; say() { echo "$*" >> $T/log; }; killall_srv() { :; }
    source ~/v0/v0d_lib.sh; source ~/v0/v0d_runner.sh; eval "$body" ); local rc=$?
  local calls=$(wc -l < $T/calls 2>/dev/null || echo 0)
  if [ $rc = $want_rc ] && [ "$calls" = "$want_calls" ]; then echo "ok   $name (rc $rc, $calls calls)"
  else echo "FAIL $name (rc $rc want $want_rc, calls $calls want $want_calls)"; sed 's/^/     /' $T/log; fails=$((fails+1)); fi; rm -rf $T; }
# explore: timeout with "SERVER EXITED" must STOP (finding 2), not skip
run_case explore-exit-timeout-stops 2 1 'explore x none cmd' EXITEVID
run_case explore-noverdict-stops 2 1 'explore x none cmd' NOVERDICT
run_case explore-loadfail-twice-skips 0 3 'explore x none cmd' LOADFAIL PASS LOADFAIL
run_case explore-devfault-recovers 0 2 'explore x none cmd' DEVFAULT PASS
run_case explore-pass 0 1 'explore x none cmd' PASS
# probes: DEVFAULT and LOADFAIL keep probing (finding 3); EVIDENCE stops
run_case probe-devfault-then-pass 0 2 'ready now' DEVFAULT PASS
run_case probe-timeout-stops 2 1 'ready now' TIMEOUT
FAULT_CAP=2 run_case fault-cap-stops 5 2 'ready now' DEVFAULT HANG
# admission set: clean set; fault in set 1 restarts the whole set; fault in both -> not eligible (rc 3)
run_case admit-clean 0 5 'admit_set A 100 none cmd' PASS PASS PASS PASS PASS
run_case admit-restart-once 0 9 'admit_set A 100 none cmd' PASS PASS HANG PASS PASS PASS PASS PASS PASS
FAULT_CAP=9 run_case admit-two-faults-not-eligible 3 6 'admit_set A 100 none cmd' PASS DEVFAULT PASS PASS PASS HANG PASS
run_case admit-evidence-stops 2 2 'admit_set A 100 none cmd' PASS TIMEOUT
run_case admit-loadfail-retry 0 7 'admit_set A 100 none cmd' PASS LOADFAIL PASS PASS PASS PASS PASS
run_case admit-loadfail-twice-stops 2 4 'admit_set A 100 none cmd' PASS LOADFAIL PASS LOADFAIL
# kernel audit (Codex review 20:32Z finding 1): a kernel fault behind a passing speed probe is a device fault (set
# restart), an unknown kernel alert stops
run_case admit-kernel-fault-restarts 0 7 'admit_set A 100 none cmd' KFAULT PASS PASS PASS PASS PASS PASS
run_case admit-kernel-unknown-stops 2 1 'admit_set A 100 none cmd' KUNKNOWN
echo "failures: $fails"; exit $fails
