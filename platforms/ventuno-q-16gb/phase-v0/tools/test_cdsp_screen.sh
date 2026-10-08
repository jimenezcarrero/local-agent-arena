#!/bin/bash
# mocked tests for v0d_cdsp_test.sh (D107 fault budget): real classify()/decide()/ready()/fault(), fake run_route,
# kernel audit, process/helper checks and restart command, driven by a plan of outcomes (one per run, in order:
# PASS, HANG, LOADFAIL, NOVERDICT). Everything under a temp dir. Refuses to run while a llama-server is up.
SRC=${SRC:-$(dirname "$(readlink -f "$0")")/v0d_cdsp_test.sh}
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
fails=0
case1() { local name=$1 want_rc=$2 want_runs=$3 want_pat=$4; shift 4
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR; printf "%s\n" "$@" > $T/plan
  cat > $T/run.sh <<'R'
#!/bin/bash
lab=$1; o=$BR/v0/$2/$lab; mkdir -p $o; out=$(head -1 $T/plan); sed -i 1d $T/plan; echo "$lab $out" >> $T/calls
: > $o/server.log; [ "$out" = NOVERDICT ] || echo pass > $o/health-verdict.txt
case $out in
 PASS) echo "t RESULT PASS (speed, health: pass, kernel evidence)" > $o/run.txt; exit 0;;
 HANG) echo "y NPU-WATCHDOG killed" >> $WD_LOG; echo "t RESULT FAIL: speed=1" > $o/run.txt; exit 1;;
 LOADFAIL) printf "t SERVER EXITED before ready (see server.log)\nt RESULT FAIL: speed=4\n" > $o/run.txt; echo "E ggml-hex: HTP0:0 buffer mapping failed : domain_id 3 size 1" > $o/server.log; exit 1;;
 NOVERDICT) echo "t RESULT PASS" > $o/run.txt; exit 0;;
 *) echo "plan exhausted" > $o/run.txt; exit 1;;
esac
R
  printf '#!/bin/bash\necho pass; exit 0\n' > $T/ka.sh; printf '#!/bin/bash\necho "$(date -Is) OK restart" ; echo RESTART >> $T/calls\n' > $T/pre.sh
  chmod +x $T/run.sh $T/ka.sh $T/pre.sh
  env RUN_ROUTE=$T/run.sh KAUDIT=$T/ka.sh PROBE_WAIT=0 CHECK_PROC=true HELPER_CHECK=true PRE_CMD=$T/pre.sh \
      bash "$SRC" > /dev/null 2>&1; local rc=$?
  local runs=$(grep -vc RESTART $T/calls 2>/dev/null); local st=$BR/v0/v0d/v0d-cdsp-test3-status.txt
  if [ $rc = $want_rc ] && [ "$runs" = "$want_runs" ] && grep -qE "$want_pat" $st; then echo "ok   $name (rc $rc, $runs runs, $(grep -c RESTART $T/calls) restarts)"
  else echo "FAIL $name (rc $rc want $want_rc; runs $runs want $want_runs; want /$want_pat/)"; sed 's/^/     /' $st; sed 's/^/     calls: /' $T/calls; fails=$((fails+1)); fi
  rm -rf $T; }
P6="PASS PASS PASS PASS PASS PASS"
case1 all-pass 0 6 "RESULT method adopted" $P6
case1 h-loadfail-not-adopted 1 6 "H loads passing after restart \+ baseline: 2/3" PASS LOADFAIL PASS PASS PASS PASS
# one fault (probe or H) -> recovery probe -> same cycle repeated from its restart; still adoptable on 3/3
case1 probe-hang-repeat 0 8 "REPEAT cycle 2 after recovery" PASS PASS HANG PASS PASS PASS PASS PASS
case1 h-hang-repeat 0 9 "RESULT method adopted" PASS HANG PASS PASS PASS PASS PASS PASS PASS
case1 second-fault-in-repeat 5 5 "second fault|fault cap 2" PASS PASS HANG PASS HANG
case1 fault-then-recovery-hang 5 4 "fault cap 2" PASS PASS HANG HANG
case1 two-faults-different-cycles 5 7 "fault cap 2|second fault" HANG PASS PASS PASS PASS PASS HANG
case1 probe-noverdict-stops 2 1 "STOP: baseline probe after restart: EVIDENCE" NOVERDICT
echo "failures: $fails"; exit $fails
