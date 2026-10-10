#!/bin/bash
# mocked tests for v0e_A_retry.sh (D136; test_v0e_A.sh plus library-identity and journal cases): fake run_v0e/run_route/kernel audit/memfloor under a temp dir; checks the exit
# code and the sequence of actions for each declared policy branch. Refuses to run while a llama-server is up.
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
fails=0
# fake run_route (baseline probes) and run_v0e (sessions); behaviour per label from $T/mode-<S1|S2|probe>:
#   pass (S2 also writes a VALID sustained summary) | nosummary (S2 PASS without it) | fail (workload failed, clean) | hang (watchdog line) | evidence (health failed) | loadfail (clean, D114)
FAKE='#!/bin/bash
lab=$1; ph=${PHASE:-$2}; o=$BR/v0/$ph/$lab; mkdir -p $o; k=probe; case $lab in *S1|*S1-retry) k=S1;; *S2|*S2-retry) k=S2;; esac
echo "$k" >> $T/calls; m=$(head -1 $T/mode-$k 2>/dev/null); m=${m:-pass}; sed -i 1d $T/mode-$k 2>/dev/null
echo pass > $o/health-verdict.txt; : > $o/server.log; echo "pass" > $o/kernel-audit.txt
case $m in
  pass|nosummary) [ $k = S2 ] && [ $m = pass ] && echo "RESULT summary: VALID (6 cycles)" > $o/sustained-summary.txt
    printf "t server pid 4242\nt RESULT PASS (workload, health: pass, kernel evidence)\n" > $o/run.txt; exit 0;;
  fail) echo "t RESULT FAIL: workload=1" > $o/run.txt; echo "t x: rc=1" > $o/items.txt; exit 1;;
  hang) echo "NPU-WATCHDOG" >> $WD_LOG; echo "t RESULT FAIL: workload=5" > $o/run.txt; exit 1;;
  evidence) echo "t RESULT FAIL: health=(fail: x)" > $o/run.txt; exit 1;;
  loadfail) printf "t SERVER EXITED before ready\nt RESULT FAIL: load=4\n" > $o/run.txt; echo "ggml-hex: HTP0:2 buffer mapping failed" > $o/server.log; exit 1;;
esac'
case1() { local name=$1 want_rc=$2 want_seq=$3; shift 3
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR
  echo "$FAKE" > $T/run.sh; printf '#!/bin/bash\necho pass; exit 0\n' > $T/ka.sh; printf 'import os, sys\nsys.exit(2 if os.path.exists(os.environ["T"] + "/mem-reject") else 0)\n' > $T/mem.py
  printf '#!/bin/bash\necho R >> $T/calls; echo OK restart\n' > $T/pre.sh; chmod +x $T/run.sh $T/ka.sh $T/pre.sh
  mkdir -p $T/htpr $T/farf; echo lib > $T/htpr/libggml-htp-v75.so; echo 0x1f > $T/farf/llama-server.farf; local rs=$(sha256sum $T/htpr/libggml-htp-v75.so | cut -d' ' -f1)
  local jl="x"; for kv in "$@"; do case $kv in RETRY_SHA=*) rs=${kv#*=};; farf=*) echo ${kv#*=} > $T/farf/llama-server.farf;; journal=*) jl=${kv#*=};; esac; done
  printf '#!/bin/bash\necho "%s"\n' "$jl" > $T/jc.sh; chmod +x $T/jc.sh
  local kv; for kv in "$@"; do case $kv in mem=reject) : > $T/mem-reject;; mode-*) echo "${kv#*=}" | tr , '\n' > $T/${kv%%=*};; esac; done
  local ex=$(( $(date +%s) + 7200 )); for kv in "$@"; do case $kv in EXPIRES=*) ex=${kv#*=};; esac; done
  env RUN_ROUTE=$T/run.sh RUN_V0E=$T/run.sh MEMFLOOR=$T/mem.py KAUDIT=$T/ka.sh PROBE_WAIT=0 SESS_PAUSE=0 CHECK_PROC=true \
      HTPR=$T/htpr FARF=$T/farf RETRY_SHA=$rs JOURNAL=$T/jc.sh bash ~/v0/v0e_A_retry.sh > $T/out.txt 2>&1; local rc=$?
  local seq=$(paste -sd' ' $T/calls 2>/dev/null)
  if [ $rc = $want_rc ] && [ "$seq" = "$want_seq" ]; then echo "ok   $name (rc $rc: $seq)"
  else echo "FAIL $name (rc $rc want $want_rc; seq '$seq' want '$want_seq')"; sed 's/^/     /' $T/out.txt | tail -8; fails=$((fails+1)); fi
  case $name in retry-logged) grep -q "DSP v0e-A-retry-S1: retried peek errors 1, longest run 1" $T/br/v0/v0d/v0e-A-retry-status.txt || { echo "FAIL retry-logged: count line"; fails=$((fails+1)); };;
    retry-repeated) grep -q "FLAG v0e-A-retry-S1: repeated peek errors (3 in a row)" $T/br/v0/v0d/v0e-A-retry-status.txt || { echo "FAIL retry-repeated: flag line"; fails=$((fails+1)); };; esac
  rm -rf $T; }
case1 all-pass 0 "probe S1 probe S2"
case1 s1-items-fail 1 "probe S1 probe S2" mode-S1=fail
case1 s1-hang 3 "probe S1 probe" mode-S1=hang
case1 baseline-hang 3 "probe probe" mode-probe=hang
case1 s1-evidence 2 "probe S1" mode-S1=evidence
case1 s2-hang 3 "probe S1 probe S2 probe" mode-S2=hang
case1 s2-evidence 2 "probe S1 probe S2" mode-S2=evidence
case1 s1-loadfail-once 0 "probe S1 probe probe S1 probe S2" mode-S1=loadfail,pass
case1 s1-loadfail-twice 3 "probe S1 probe probe S1" mode-S1=loadfail,loadfail
case1 s2-loadfail-once 0 "probe S1 probe S2 probe probe S2" mode-S2=loadfail,pass
case1 loadfail-then-recovery-hang 3 "probe S1 probe probe" mode-S1=loadfail mode-probe=pass,hang
case1 a-s1-memreject 3 "probe S1" mem=reject
case1 s2-no-summary 2 "probe S1 probe S2" mode-S2=nosummary
# D136: the patched library and .farf file are checked before and after each session; retries are counted, not faults
case1 wrong-library-stops 2 "probe" RETRY_SHA=0000
case1 farf-changed-stops 2 "probe" farf=0x0
case1 retry-logged 0 "probe S1 probe S2" "journal=CDSP0: dspqueue_peek failed: 0x0000002f (1 in a row), retrying"
case1 retry-repeated 0 "probe S1 probe S2" "journal=CDSP0: dspqueue_peek failed: 0x0000002f (3 in a row), retrying"
echo "failures: $fails"; exit $fails
