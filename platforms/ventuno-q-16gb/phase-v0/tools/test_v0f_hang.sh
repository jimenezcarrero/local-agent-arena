#!/bin/bash
# mocked tests for v0f_hang.sh (D122; derived from test_v0e_A.sh): fake run_v0e/run_route/kernel audit/memfloor under a temp dir; checks the exit
# code and the sequence of actions for each declared policy branch. Refuses to run while a llama-server is up.
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
fails=0
# fake run_route (baseline probes) and run_v0e (sessions); behaviour per label from $T/mode-<S1|S2|probe>:
#   pass (S2 also writes a VALID sustained summary) | nosummary (S2 PASS without it) | fail (workload failed, clean) | hang (watchdog line) | evidence (health failed) | loadfail (clean, D114)
FAKE='#!/bin/bash
lab=$1; ph=${PHASE:-$2}; o=$BR/v0/$ph/$lab; mkdir -p $o; k=probe; case $lab in v0f-W-*) k=W;; v0f-B-*) k=B;; esac
echo "$k" >> $T/calls; m=$(head -1 $T/mode-$k 2>/dev/null); m=${m:-pass}; sed -i 1d $T/mode-$k 2>/dev/null
echo pass > $o/health-verdict.txt; : > $o/server.log; echo "pass" > $o/kernel-audit.txt
case $m in
  pass|nosummary) [ $k = S2 ] && [ $m = pass ] && echo "RESULT summary: VALID (6 cycles)" > $o/sustained-summary.txt
    echo {\"ok\": true} > $o/stress.jsonl; echo "t RESULT PASS (workload, health: pass, kernel evidence)" > $o/run.txt; exit 0;;
  fail) echo "t RESULT FAIL: workload=1" > $o/run.txt; echo "t x: rc=1" > $o/items.txt; exit 1;;
  hang) echo "NPU-WATCHDOG" >> $WD_LOG; echo "t RESULT FAIL: workload=5" > $o/run.txt; exit 1;;
  evidence) echo "t RESULT FAIL: health=(fail: x)" > $o/run.txt; exit 1;;
  loadfail) printf "t SERVER EXITED before ready\nt RESULT FAIL: load=4\n" > $o/run.txt; echo "ggml-hex: HTP0:2 buffer mapping failed" > $o/server.log; exit 1;;
esac'
case1() { local name=$1 want_rc=$2 want_seq=$3; shift 3
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR
  echo "$FAKE" > $T/run.sh; printf '#!/bin/bash\necho pass; exit 0\n' > $T/ka.sh; printf 'import os, sys\nsys.exit(2 if os.path.exists(os.environ["T"] + "/mem-reject") else 0)\n' > $T/mem.py
  printf '#!/bin/bash\necho R >> $T/calls; echo OK restart\n' > $T/pre.sh; chmod +x $T/run.sh $T/ka.sh $T/pre.sh
  local kv; for kv in "$@"; do case $kv in mem=reject) : > $T/mem-reject;; mode-*) echo "${kv#*=}" | tr , '\n' > $T/${kv%%=*};; esac; done
  local fc=8; for kv in "$@"; do case $kv in FAULT_CAP=*) fc=${kv#*=};; esac; done
  env RUN_ROUTE=$T/run.sh RUN_V0E=$T/run.sh MEMFLOOR=$T/mem.py KAUDIT=$T/ka.sh PROBE_WAIT=0 SESS_PAUSE=0 N_SESS=2 N_REQ=1 CHECK_PROC=true FAULT_CAP=$fc \
      bash ~/v0/v0f_hang.sh > $T/out.txt 2>&1; local rc=$?
  local seq=$(paste -sd' ' $T/calls 2>/dev/null)
  if [ $rc = $want_rc ] && [ "$seq" = "$want_seq" ]; then echo "ok   $name (rc $rc: $seq)"
  else echo "FAIL $name (rc $rc want $want_rc; seq '$seq' want '$want_seq')"; sed 's/^/     /' $T/out.txt | tail -8; fails=$((fails+1)); fi
  rm -rf $T; }
case1 all-pass 0 "probe W probe B probe W probe B"
case1 b-hang-continues 0 "probe W probe B probe probe W probe B" mode-B=hang,pass
case1 w-and-b-hang-continue 0 "probe W probe probe B probe probe W probe B" mode-W=hang,pass mode-B=hang,pass
case1 two-loadfails-stop 2 "probe W probe probe B" mode-W=loadfail mode-B=loadfail
case1 loadfail-then-pass 0 "probe W probe probe B probe W probe B" mode-W=loadfail,pass
case1 evidence-stops 2 "probe W" mode-W=evidence
case1 fault-cap 5 "probe W probe probe B" mode-W=hang mode-B=hang FAULT_CAP=2
case1 baseline-hang-recovers 0 "probe probe W probe B probe W probe B" mode-probe=hang,pass
echo "failures: $fails"; exit $fails
