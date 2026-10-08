#!/bin/bash
# mocked tests for the v0d_admit.sh entry point (Codex review of #47, 22:08Z): H2 checks its helper before any load and
# its first NPU action is the restart (no plain initial probe); other sets keep the initial probe. Fake run_route,
# memfloor, process check and helper; everything under a temp dir. Refuses to run while a llama-server is up.
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
fails=0
case1() { local name=$1 set=$2 want_rc=$3 want_first=$4; shift 4
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR
  printf '#!/bin/bash\nlab=$1; o=$BR/v0/$2/$lab; [ -n "${PHASE:-}" ] && o=$BR/v0/$PHASE/$lab; mkdir -p $o; echo "$lab" >> $T/calls\necho "t RESULT PASS (speed, health: pass, kernel evidence)" > $o/run.txt; echo pass > $o/health-verdict.txt; : > $o/server.log; exit 0\n' > $T/run.sh
  printf '#!/bin/bash\nv="pass|0"; echo "${v%%|*}"; exit 0\n' > $T/ka.sh; printf 'import sys\nsys.exit(0)\n' > $T/mem.py
  printf '#!/bin/bash\necho PRELOAD >> $T/calls; echo OK restart\n' > $T/pre.sh; chmod +x $T/run.sh $T/ka.sh $T/pre.sh
  env "$@" RUN_ROUTE=$T/run.sh RUN_V0C=$T/run.sh MEMFLOOR=$T/mem.py KAUDIT=$T/ka.sh PROBE_WAIT=0 SET_PAUSE=0 CHECK_PROC=true \
      PRE_CMD=$T/pre.sh bash ~/v0/v0d_admit.sh $set > /dev/null 2>&1; local rc=$?
  local first=$(head -1 $T/calls 2>/dev/null); first=${first%%-*}
  if [ $rc = $want_rc ] && [ "${first:-none}" = "$want_first" ]; then echo "ok   $name (rc $rc, first action: ${first:-none})"
  else echo "FAIL $name (rc $rc want $want_rc; first ${first:-none} want $want_first)"; sed 's/^/     /' $T/calls 2>/dev/null; fails=$((fails+1)); fi
  rm -rf $T; }
case1 h2-helper-missing H2 6 none HELPER_CHECK=false
case1 h2-restart-first H2 0 PRELOAD HELPER_CHECK=true
case1 a-probe-first A 0 probe HELPER_CHECK=false
echo "failures: $fails"; exit $fails
