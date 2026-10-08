#!/bin/bash
# mocked tests for v0d_interleave.sh (D100, Codex review of #47 2026-10-08 05:13Z): a PASS run whose memfloor --admit
# fails (REJECT 1, no samples 2) must stop the comparison with exit 3, never advance or report "done". Fake run_route,
# kernel audit, memfloor and process check; everything under a temp dir. Refuses to run while a llama-server is up.
SRC=${SRC:-$(dirname "$(readlink -f "$0")")/v0d_interleave.sh}
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
fails=0
case1() { local name=$1 mem_rc=$2 want_rc=$3 want_runs=$4 want_pat=$5
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR
  printf '#!/bin/bash\nlab=$1; o=$BR/v0/$2/$lab; [ -n "${PHASE:-}" ] && o=$BR/v0/$PHASE/$lab; mkdir -p $o; echo "$lab" >> $T/calls\necho "t RESULT PASS (speed, health: pass, kernel evidence)" > $o/run.txt; echo pass > $o/health-verdict.txt; : > $o/server.log; exit 0\n' > $T/run.sh
  printf '#!/bin/bash\necho pass; exit 0\n' > $T/ka.sh
  printf 'import sys\nprint("REJECT x | no samples in the run window" if %s == 2 else ("REJECT x L_min_kB=1" if %s else "ADMIT x"))\nsys.exit(%s)\n' $mem_rc $mem_rc $mem_rc > $T/mem.py
  chmod +x $T/run.sh $T/ka.sh
  env RUN_ROUTE=$T/run.sh RUN_V0C=$T/run.sh MEMFLOOR=$T/mem.py KAUDIT=$T/ka.sh PROBE_WAIT=0 SET_PAUSE=0 CHECK_PROC=true \
      bash "$SRC" > /dev/null 2>&1; local rc=$?
  local runs=$(grep -vc '^probe' $T/calls 2>/dev/null); local st=$BR/v0/v0d/v0d-interleave-status.txt
  if [ $rc = $want_rc ] && [ "$runs" = "$want_runs" ] && grep -qE "$want_pat" $st; then echo "ok   $name (rc $rc, $runs runs)"
  else echo "FAIL $name (rc $rc want $want_rc; runs $runs want $want_runs; want /$want_pat/)"; sed 's/^/     /' $st; fails=$((fails+1)); fi
  rm -rf $T; }
case1 mem-admit-completes 0 0 6 "interleave done \(faults 0\)"
case1 mem-reject-stops 1 3 1 "STOP: MEM A-1: REJECT"
case1 mem-missing-stops 2 3 1 "STOP: MEM A-1: REJECT x \| no samples"
echo "failures: $fails"; exit $fails
