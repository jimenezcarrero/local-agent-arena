#!/bin/bash
# mocked tests for v0e_A_retry.sh (D136, D137; test_v0e_A.sh plus library identity, admission precondition, runner
# exit status and fail-closed DSP journal cases): fake run_v0e/run_route/kernel audit/memfloor/journalctl under a temp
# dir; checks the exit code and the sequence of actions for each declared policy branch. Refuses to run while a
# llama-server is up.
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
fails=0
# fake run_route (baseline probes) and run_v0e (sessions); behaviour per label from $T/mode-<S1|S2|probe>:
#   pass (S2 also writes a VALID sustained summary) | nosummary | fail (S1 items failed, clean, rc 1) | hang (watchdog
#   line) | evidence (health failed) | loadfail (clean, D114) | fail-timeout / fail-killed / fail-health (S1 item-failure
#   records with rc 124 / rc 137 / a failed health verdict) | loadfail-timeout / loadfail-killed (load=4 with rc 124/137)
FAKE='#!/bin/bash
lab=$1; ph=${PHASE:-$2}; o=$BR/v0/$ph/$lab; mkdir -p $o; k=probe; case $lab in *S1|*S1-retry) k=S1;; *S2|*S2-retry) k=S2;; esac
echo "$k" >> $T/calls; m=$(head -1 $T/mode-$k 2>/dev/null); m=${m:-pass}; sed -i 1d $T/mode-$k 2>/dev/null
echo pass > $o/health-verdict.txt; : > $o/server.log; echo "pass" > $o/kernel-audit.txt
S="2026-10-11T10:00:00+02:00 START label=$lab boot=b00t-1\n2026-10-11T10:00:01+02:00 server pid 4242\n"
R="2026-10-11T10:00:30+02:00 ready after 29s\n"; E="2026-10-11T10:30:00+02:00 END load=0\n"; U="t server still up at the end of the workload\n"
case $m in
  pass|nosummary) [ $k = S2 ] && [ $m = pass ] && echo "RESULT summary: VALID (6 cycles)" > $o/sustained-summary.txt
    printf "$S$R$U${E}t RESULT PASS (workload, health: pass, kernel evidence)\n" > $o/run.txt; exit 0;;
  pass-nopid) printf "2026-10-11T10:00:00+02:00 START label=$lab boot=b00t-1\n$R$U${E}t RESULT PASS (workload, health: pass, kernel evidence)\n" > $o/run.txt; exit 0;;
  fail) printf "$S$R$U${E}t RESULT FAIL: workload=1\n" > $o/run.txt; echo "t x: rc=1" > $o/items.txt; exit 1;;
  fail-timeout) printf "$S$R$U${E}t RESULT FAIL: workload=1\n" > $o/run.txt; echo "t x: rc=1" > $o/items.txt; exit 124;;
  fail-killed) printf "$S$R$U${E}t RESULT FAIL: workload=1\n" > $o/run.txt; echo "t x: rc=1" > $o/items.txt; exit 137;;
  fail-health) echo "fail: missing kernel read" > $o/health-verdict.txt; printf "$S$R$U${E}t RESULT FAIL: workload=1\n" > $o/run.txt; exit 1;;
  hang) echo "NPU-WATCHDOG" >> $WD_LOG; printf "$S$R${E}t RESULT FAIL: workload=5\n" > $o/run.txt; exit 1;;
  evidence) printf "$S$R$U${E}t RESULT FAIL: health=(fail: x)\n" > $o/run.txt; exit 1;;
  loadfail|loadfail-timeout|loadfail-killed) printf "${S}t SERVER EXITED before ready\n${E}t RESULT FAIL: load=4\n" > $o/run.txt
    echo "ggml-hex: HTP0:2 buffer mapping failed" > $o/server.log
    case $m in loadfail) exit 1;; loadfail-timeout) exit 124;; *) exit 137;; esac;;
esac'
JOK='2026-10-11T10:00:02+02:00 ventunoq llama-server[4242]: ./src/apps_std_imp.c:1043: Successfully opened file libggml-htp-v75.so
2026-10-11T10:00:02+02:00 ventunoq llama-server[4242]: adsprpc 2;479d:786: CDSP0: PERF: name:./libggml-htp-v75.so'
case1() { local name=$1 want_rc=$2 want_seq=$3; shift 3
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR/v0/v0d
  echo "$FAKE" > $T/run.sh; printf '#!/bin/bash\necho pass; exit 0\n' > $T/ka.sh; printf 'import os, sys\nsys.exit(2 if os.path.exists(os.environ["T"] + "/mem-reject") else 0)\n' > $T/mem.py
  chmod +x $T/run.sh $T/ka.sh
  mkdir -p $T/htpr $T/farf; echo lib > $T/htpr/libggml-htp-v75.so; echo 0x1f > $T/farf/llama-server.farf; local rs=$(sha256sum $T/htpr/libggml-htp-v75.so | cut -d' ' -f1)
  echo "2026-10-11T09:00:00+02:00 GATE AR: PASS (median 16K 317.4/8.22)" > $BR/v0/v0d/v0d-admit-AR-status.txt
  local jmode=ok jextra=""; local kv
  for kv in "$@"; do case $kv in RETRY_SHA=*) rs=${kv#*=};; farf=*) echo ${kv#*=} > $T/farf/llama-server.farf;; jextra=*) jextra=${kv#*=};; jmode=*) jmode=${kv#*=};;
    noadmit) : > $BR/v0/v0d/v0d-admit-AR-status.txt;; mem=reject) : > $T/mem-reject;; mode-*) echo "${kv#*=}" | tr , '\n' > $T/${kv%%=*};; esac; done
  printf '%s\n%s\n' "$JOK" "$jextra" > $T/journal-ok.txt; echo $jmode > $T/jmode
  # fake journalctl: records its arguments; ok | fail (rc 1) | empty | nocdsp (no DSP lines)
  printf '#!/bin/bash\necho "$*" >> $T/jargs\ncase $(cat $T/jmode) in ok) cat $T/journal-ok.txt;; fail) echo "journal error" >&2; exit 1;; empty) :;; nocdsp) grep -v CDSP0 $T/journal-ok.txt;; esac\n' > $T/jc.sh; chmod +x $T/jc.sh
  env RUN_ROUTE=$T/run.sh RUN_V0E=$T/run.sh MEMFLOOR=$T/mem.py KAUDIT=$T/ka.sh PROBE_WAIT=0 SESS_PAUSE=0 CHECK_PROC=true \
      HTPR=$T/htpr FARF=$T/farf RETRY_SHA=$rs JOURNAL=$T/jc.sh bash ~/v0/v0e_A_retry.sh > $T/out.txt 2>&1; local rc=$?
  local seq=$(paste -sd' ' $T/calls 2>/dev/null) st=$BR/v0/v0d/v0e-A-retry-status.txt
  if [ $rc = $want_rc ] && [ "$seq" = "$want_seq" ]; then echo "ok   $name (rc $rc: $seq)"
  else echo "FAIL $name (rc $rc want $want_rc; seq '$seq' want '$want_seq')"; sed 's/^/     /' $T/out.txt | tail -8; fails=$((fails+1)); fi
  chk() { grep -q -- "$1" "$2" || { echo "FAIL $name: no '$1' in $(basename $2)"; fails=$((fails+1)); }; }
  case $name in
    retry-logged) chk "DSP v0e-A-retry-S1: logged retry events 1, longest run 1" $st;;
    retry-repeated) chk "FLAG v0e-A-retry-S1: repeated peek errors (3 in a row)" $st;;
    all-pass) chk "_PID=4242 _BOOT_ID=b00t1 --since 2026-10-11 10:00:00 --until 2026-10-11 10:31:00" $T/jargs;;
    journal-fail-hang-stands) chk "NOT QUALIFIED (fault HANG" $st;;
  esac
  rm -rf $T; }
# D118 policy cases (unchanged expectations)
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
# D136: library identity; retries counted, not faults
case1 wrong-library-stops 2 "probe" RETRY_SHA=0000
case1 farf-changed-stops 2 "probe" farf=0x0
case1 retry-logged 0 "probe S1 probe S2" "jextra=2026-10-11T10:05:00+02:00 x: adsprpc CDSP0: dspqueue_peek failed: 0x0000002f (1 in a row), retrying"
case1 retry-repeated 0 "probe S1 probe S2" "jextra=2026-10-11T10:05:00+02:00 x: adsprpc CDSP0: dspqueue_peek failed: 0x0000002f (3 in a row), retrying"
# D137 (Codex review of 6f203ab): admission precondition; abnormal runner exits and failed health are not recoverable;
# DSP evidence must be captured
case1 no-admission-stops 6 "" noadmit
case1 loadfail-timeout-stops 2 "probe S1" mode-S1=loadfail-timeout
case1 loadfail-killed-stops 2 "probe S1" mode-S1=loadfail-killed
case1 s1-fail-timeout-stops 2 "probe S1" mode-S1=fail-timeout
case1 s1-fail-killed-stops 2 "probe S1" mode-S1=fail-killed
case1 s1-fail-health-stops 2 "probe S1" mode-S1=fail-health
case1 journal-fail-stops 2 "probe S1" jmode=fail
case1 journal-empty-stops 2 "probe S1" jmode=empty
case1 journal-no-dsp-lines-stops 2 "probe S1" jmode=nocdsp
case1 journal-no-pid-stops 2 "probe S1" mode-S1=pass-nopid
case1 journal-fail-hang-stands 3 "probe S1 probe" jmode=fail mode-S1=hang
echo "failures: $fails"; exit $fails
