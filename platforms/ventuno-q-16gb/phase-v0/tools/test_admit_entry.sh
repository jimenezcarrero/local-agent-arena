#!/bin/bash
# mocked tests for the v0d_admit.sh entry point (Codex review of #47, 22:08Z): H2 checks its helper before any load and
# its first NPU action is the restart (no plain initial probe); other sets keep the initial probe. Fake run_route,
# memfloor, process check and helper; everything under a temp dir. Refuses to run while a llama-server is up.
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
fails=0
case1() { local name=$1 set=$2 want_rc=$3 want_first=$4; shift 4
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR
  # fake runner: PASS with a 16384 probe RESULT line; LOADFAIL_LAB=<label> makes that label's first run a clean load
  # failure (D138: the admitted step is then read from <label>-retry)
  printf '#!/bin/bash\nlab=$1; o=$BR/v0/$2/$lab; [ -n "${PHASE:-}" ] && o=$BR/v0/$PHASE/$lab; mkdir -p $o; echo "$lab" >> $T/calls\necho pass > $o/health-verdict.txt; : > $o/server.log\nif [ "$lab" = "${LOADFAIL_LAB:-}" ]; then printf "t SERVER EXITED before ready\\nt RESULT FAIL: speed=4\\n" > $o/run.txt; echo "ggml-hex: HTP0:1 buffer mapping failed" > $o/server.log; exit 1; fi\necho "t RESULT PASS (speed, health: pass, kernel evidence)" > $o/run.txt; echo "RESULT $lab: depth=16384 prompt_tokens=18000 ttft=1s prefill_tps=300.0 gen_tokens=128 decode_tps=8.00 method=usage" > $o/probe.txt; exit 0\n' > $T/run.sh
  printf '#!/bin/bash\nv="pass|0"; echo "${v%%|*}"; exit 0\n' > $T/ka.sh; printf 'import sys\nsys.exit(0)\n' > $T/mem.py
  printf '#!/bin/bash\necho PRELOAD >> $T/calls; echo OK restart\n' > $T/pre.sh; chmod +x $T/run.sh $T/ka.sh $T/pre.sh
  # AR (D137): fake library check (ok, fail, or fail from its Nth call: lib-fail-at) and fake 16K gate (exit from gate-rc)
  printf '#!/bin/bash\nn=$(( $(cat $T/hc 2>/dev/null || echo 0) + 1 )); echo $n > $T/hc\nif [ -n "${LIBFAIL_AT:-}" ] && [ $n -ge $LIBFAIL_AT ]; then echo "FAILED htp-retry sha256"; exit 1; fi\necho "OK htp-retry sha256"\n' > $T/hcheck.sh
  printf '#!/bin/bash\necho "$*" > $T/gate-args; case ${GATE_RC:-0} in 0) echo "GATE AR: PASS median 16K prefill 317.4";; 3) echo "GATE AR: FAIL median 16K prefill 120.0";; *) echo "GATE AR: MISSING";; esac; exit ${GATE_RC:-0}\n' > $T/gate.sh
  chmod +x $T/hcheck.sh $T/gate.sh
  env RUN_ROUTE=$T/run.sh RUN_V0C=$T/run.sh MEMFLOOR=$T/mem.py KAUDIT=$T/ka.sh PROBE_WAIT=0 SET_PAUSE=0 CHECK_PROC=true \
      PRE_CMD=$T/pre.sh HTPR_CHECK=$T/hcheck.sh GATE=$T/gate.sh "$@" bash ~/v0/v0d_admit.sh $set > /dev/null 2>&1; local rc=$?
  local first=$(head -1 $T/calls 2>/dev/null); first=${first%%-*}
  if [ $rc = $want_rc ] && [ "${first:-none}" = "$want_first" ]; then echo "ok   $name (rc $rc, first action: ${first:-none})"
  else echo "FAIL $name (rc $rc want $want_rc; first ${first:-none} want $want_first)"; sed 's/^/     /' $T/calls 2>/dev/null; fails=$((fails+1)); fi
  case $name in ar-load-retry-real-gate) grep -q "GATE AR: PASS .*AR-s1-r2-retry 18000 tok" $BR/v0/v0d/v0d-admit-AR-status.txt \
      || { echo "FAIL ar-load-retry-real-gate: gate did not read AR-s1-r2-retry"; fails=$((fails+1)); };; esac
  case $name in ar-pass) grep -q "GATE AR: PASS" $BR/v0/v0d/v0d-admit-AR-status.txt && [ "$(cat $T/gate-args)" = "$BR/v0/v0d-admit-AR AR 1" ] \
      && [ "$(cat $T/hc)" = 7 ] || { echo "FAIL ar-pass: gate line, gate arguments or 7 library checks (start, 5 steps, after)"; fails=$((fails+1)); };; esac
  rm -rf $T; }
case1 h2-helper-missing H2 6 none HELPER_CHECK=false
case1 h2-restart-first H2 0 PRELOAD HELPER_CHECK=true
case1 a-probe-first A 0 probe HELPER_CHECK=false
# D137: AR checks the patched library before anything, before every step and after the set, then the 16K gate
case1 ar-pass AR 0 probe HELPER_CHECK=false
case1 ar-library-wrong AR 6 none LIBFAIL_AT=1
case1 ar-library-changes-mid-set AR 2 probe LIBFAIL_AT=3
case1 ar-library-changes-after-set AR 2 probe LIBFAIL_AT=7
case1 ar-gate-fail AR 3 probe GATE_RC=3
case1 ar-gate-missing AR 2 probe GATE_RC=2
# D138: integration with the real gate: r2 fails to load once (clean), its retry passes, the gate reads the retry
case1 ar-load-retry-real-gate AR 0 probe LOADFAIL_LAB=AR-s1-r2 GATE="python3 $HOME/v0/admit_gate.py"
echo "failures: $fails"; exit $fails
