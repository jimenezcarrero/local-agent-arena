#!/bin/bash
# mocked tests for v0e_A_retry.sh (D136, D137; test_v0e_A.sh plus library identity, admission precondition, runner
# exit status and fail-closed DSP journal cases): fake run_v0e/run_route/kernel audit/memfloor/journalctl under a temp
# dir; checks the exit code and the sequence of actions for each declared policy branch. Refuses to run while a
# llama-server is up.
# D157: SET=A32 runs the same cases against "v0e_A_retry.sh A32" (its own admission status and phase), plus the A32
# command/cap checks; SET=AR (default) as before plus AR's command/cap check.
pgrep -x llama-server > /dev/null && { echo "a llama-server is running; not testing"; exit 9; }
# D161: SET=A32 ATT=2 runs them against "v0e_A_retry.sh A32 2" (phase v0e-A32-2, A32's admission; baseline probes on
# the patched library, whose identity is checked before every baseline), plus the baseline command check.
# D167: SET=A32 ATT=3 runs them against "v0e_A_retry.sh A32 3" (as attempt 2 plus stage S0 before S1): every case's
# expected sequence gains "probe S0" before "probe S1" and its baseline-probe modes a passing probe for S0; plus the S0
# rule cases.
# D171: SET=A32 ATT=4 runs them against "v0e_A_retry.sh A32 4" (as attempt 3 without S0: the attempt-2 sequences);
# every set: a passing session's server log gets a COST status line (server_requests.py, reported). Run with HOME at a
# scratch tree holding the revision's tools as ~/v0 (the deployed copy is updated only at an approved launch).
# D174: SET=A32 ATT=5 runs them against "v0e_A_retry.sh A32 5" (as attempt 4).
SET=${SET:-AR}; ATT=${ATT:-1}; case $SET/$ATT in AR/1) NAME=A-retry;; A32/1) NAME=A32;; A32/2) NAME=A32-2;; A32/3) NAME=A32-3;; A32/4) NAME=A32-4;; A32/5) NAME=A32-5;; *) echo "SET/ATT must be AR/1, A32/1, A32/2, A32/3, A32/4 or A32/5"; exit 9;; esac
ARGS="$SET"; [ $ATT -ge 2 ] && ARGS="$SET $ATT"
fails=0
# fake run_route (baseline probes) and run_v0e (sessions); behaviour per label from $T/mode-<S1|S2|probe>:
#   pass (S2 also writes a VALID sustained summary) | nosummary | fail (S1 items failed, clean, rc 1) | hang (watchdog
#   line) | evidence (health failed) | loadfail (clean, D114) | fail-timeout / fail-killed / fail-health (S1 item-failure
#   records with rc 124 / rc 137 / a failed health verdict) | loadfail-timeout / loadfail-killed (load=4 with rc 124/137)
FAKE='#!/bin/bash
lab=$1; ph=${PHASE:-$2}; o=$BR/v0/$ph/$lab; mkdir -p $o; k=probe; case $lab in *S0|*S0-retry) k=S0;; *S1|*S1-retry) k=S1;; *S2|*S2-retry) k=S2;; esac
echo "$k" >> $T/calls; echo "$k $*" >> $T/cmds; echo "$k ${CACHE_WORDING:-unset}" >> $T/wordings
[ $k = S0 ] && { w=$(cat $T/wording 2>/dev/null || echo "WORDING: current 2/8, neutral 8/8"); [ "$w" = none ] || echo "$w" > $o/workload.txt; }
m=$(head -1 $T/mode-$k 2>/dev/null); m=${m:-pass}; sed -i 1d $T/mode-$k 2>/dev/null
echo pass > $o/health-verdict.txt; echo "pass" > $o/kernel-audit.txt
printf "x | task 7 | new prompt, n_ctx_slot = 32768, n_keep = 0, task.n_tokens = 900\nx | task 7 | prompt eval time =   4000.00 ms /   900 tokens\n" > $o/server.log
S="2026-10-11T10:00:00+02:00 START label=$lab boot=b00t-1\n2026-10-11T10:00:01+02:00 server pid 4242\n"
R="2026-10-11T10:00:30+02:00 ready after 29s\n"; E="2026-10-11T10:30:00+02:00 END load=0\n"; U="t server still up at the end of the workload\n"
case $m in
  pass|nosummary) [ $k = S2 ] && [ $m = pass ] && echo "RESULT summary: VALID (6 cycles)" > $o/sustained-summary.txt
    printf "$S$R$U${E}t RESULT PASS (workload, health: pass, kernel evidence)\n" > $o/run.txt; exit 0;;
  pass-noready) printf "$S$U${E}t RESULT PASS (workload, health: pass, kernel evidence)\n" > $o/run.txt
    [ $k = S2 ] && echo "RESULT summary: VALID (6 cycles)" > $o/sustained-summary.txt; exit 0;;
  pass-nopid) printf "2026-10-11T10:00:00+02:00 START label=$lab boot=b00t-1\n$R$U${E}t RESULT PASS (workload, health: pass, kernel evidence)\n" > $o/run.txt; exit 0;;
  fail) printf "$S$R$U${E}t RESULT FAIL: workload=1\n" > $o/run.txt; echo "t x: rc=1" > $o/items.txt; exit 1;;
  fail-timeout) printf "$S$R$U${E}t RESULT FAIL: workload=1\n" > $o/run.txt; echo "t x: rc=1" > $o/items.txt; exit 124;;
  fail-killed) printf "$S$R$U${E}t RESULT FAIL: workload=1\n" > $o/run.txt; echo "t x: rc=1" > $o/items.txt; exit 137;;
  fail-health) echo "fail: missing kernel read" > $o/health-verdict.txt; printf "$S$R$U${E}t RESULT FAIL: workload=1\n" > $o/run.txt; exit 1;;
  hang|hang-farf|hang-pkg) echo "NPU-WATCHDOG" >> $WD_LOG; printf "$S$R${E}t RESULT FAIL: workload=5\n" > $o/run.txt
    [ $m = hang-farf ] && echo 0x0 > $T/farf/llama-server.farf; [ $m = hang-pkg ] && echo x >> $T/pkg/lib/libllama.so.0.5.0; exit 1;;
  pass-pkg) printf "$S$R$U${E}t RESULT PASS (workload, health: pass, kernel evidence)\n" > $o/run.txt
    echo x >> $T/pkg/lib/libllama.so.0.5.0; exit 0;;
  loadfail-farf) printf "${S}t SERVER EXITED before ready\n${E}t RESULT FAIL: speed=4\n" > $o/run.txt  # a baseline (run_route) load failure
    echo "ggml-hex: HTP0:2 buffer mapping failed" > $o/server.log; echo 0x0 > $T/farf/llama-server.farf; exit 1;;
  evidence) printf "$S$R$U${E}t RESULT FAIL: health=(fail: x)\n" > $o/run.txt; exit 1;;
  loadfail|loadfail-timeout|loadfail-killed) printf "${S}t SERVER EXITED before ready\n${E}t RESULT FAIL: load=4\n" > $o/run.txt
    echo "ggml-hex: HTP0:2 buffer mapping failed" > $o/server.log
    case $m in loadfail) exit 1;; loadfail-timeout) exit 124;; *) exit 137;; esac;;
esac'
JOK='2026-10-11T10:00:02+02:00 ventunoq llama-server[4242]: ./src/apps_std_imp.c:1043: Successfully opened file libggml-htp-v75.so
2026-10-11T10:00:02+02:00 ventunoq llama-server[4242]: adsprpc 2;479d:786: CDSP0: PERF: name:./libggml-htp-v75.so'
case1() { local name=$1 want_rc=$2 want_seq=$3; shift 3
  # D167: attempt 3 runs S0 (its own passing baseline) before S1
  if [ $ATT = 3 ] && [[ "$want_seq" == "probe S1"* ]]; then want_seq="probe S0 $want_seq"
    local a nargs=(); for a in "$@"; do case $a in mode-probe=*) a="mode-probe=pass,${a#mode-probe=}";; jmode=*) a="jmode=ok,${a#jmode=}";; esac; nargs+=("$a"); done; set -- "${nargs[@]}"; fi
  T=$(mktemp -d); export T BR=$T/br WD_LOG=$T/wd.txt; echo x > $WD_LOG; mkdir -p $BR/v0/v0d
  echo "$FAKE" > $T/run.sh; printf '#!/bin/bash\necho pass; exit 0\n' > $T/ka.sh; printf 'import os, sys\nT = os.environ["T"]; open(T + "/caps", "a").write(sys.argv[2] + "\\n")\nr = open(T + "/mem-reject").read().strip() if os.path.exists(T + "/mem-reject") else ""\nsys.exit(2 if r and r in os.path.basename(sys.argv[3]) else 0)\n' > $T/mem.py
  chmod +x $T/run.sh $T/ka.sh
  # D176: a fake release package (a library, a symlink chain) and its manifest, made with the real pkg_identity.py
  mkdir -p $T/pkg/bin $T/pkg/lib; echo srv > $T/pkg/bin/llama-server; echo llama > $T/pkg/lib/libllama.so.0.5.0
  ln -s libllama.so.0.5.0 $T/pkg/lib/libllama.so.0; ln -s libllama.so.0 $T/pkg/lib/libllama.so
  (cd $T/pkg && sha256sum ./bin/llama-server ./lib/libllama.so.0.5.0) > $T/pkg-record.sha256
  python3 ~/v0/pkg_identity.py make $T/pkg-record.sha256 $T/pkg > $T/pkgman
  mkdir -p $T/htpr $T/farf; echo lib > $T/htpr/libggml-htp-v75.so; echo 0x1f > $T/farf/llama-server.farf; local rs=$(sha256sum $T/htpr/libggml-htp-v75.so | cut -d' ' -f1)
  A1="2026-10-11T08:00:00+02:00 admission $SET start (pid 1)
2026-10-11T08:50:00+02:00 SET $SET: ADMITTED in attempt 1 (set faults: 0)
2026-10-11T08:50:01+02:00 GATE $SET: PASS median 16K prefill 317.4 (>= 145), decode 8.22 (>= 4.4)
2026-10-11T08:50:02+02:00 admission $SET done rc=0 (faults 0)"
  echo "$A1" > $BR/v0/v0d/v0d-admit-$SET-status.txt
  printf '#!/bin/bash\necho "$*" > $T/gate-args; [ -f $T/gate-fail ] && { echo "GATE AR: FAIL"; exit 3; }; echo "GATE AR: PASS median 16K prefill 317.4"\n' > $T/gate.sh; chmod +x $T/gate.sh
  local jmode=ok jextra=""; local kv
  for kv in "$@"; do case $kv in RETRY_SHA=*) rs=${kv#*=};; farf=*) echo ${kv#*=} > $T/farf/llama-server.farf;; jextra=*) jextra=${kv#*=};; jmode=*) jmode=${kv#*=};;
    noadmit) : > $BR/v0/v0d/v0d-admit-$SET-status.txt;;
    admit-newer-fail) printf '%s\n' "2026-10-11T09:00:00+02:00 admission $SET start (pid 2)" "2026-10-11T09:50:00+02:00 SET $SET: ADMITTED in attempt 1 (set faults: 0)" "2026-10-11T09:50:01+02:00 GATE $SET: FAIL median 16K prefill 120.0" "2026-10-11T09:50:02+02:00 admission $SET done rc=3 (faults 0)" >> $BR/v0/v0d/v0d-admit-$SET-status.txt;;
    admit-newer-unfinished) echo "2026-10-11T09:00:00+02:00 admission $SET start (pid 2)" >> $BR/v0/v0d/v0d-admit-$SET-status.txt;;
    gate-fail) : > $T/gate-fail;;
    pkg=modified) echo x >> $T/pkg/lib/libllama.so.0.5.0;; pkg=missing) rm $T/pkg/lib/libllama.so.0.5.0;;
    pkg=redirect) rm $T/pkg/lib/libllama.so.0; ln -s ../bin/llama-server $T/pkg/lib/libllama.so.0;; pkg=extra) echo e > $T/pkg/lib/libggml-extra.so;;
    other-set-admission) mv $BR/v0/v0d/v0d-admit-$SET-status.txt $BR/v0/v0d/v0d-admit-AR-status.txt;; mem=reject) echo S1 > $T/mem-reject;; mem=reject-S0) echo S0 > $T/mem-reject;; wording=*) echo "${kv#wording=}" > $T/wording;; mode-*) echo "${kv#*=}" | tr , '\n' > $T/${kv%%=*};; esac; done
  printf '%s\n%s\n' "$JOK" "$jextra" > $T/journal-ok.txt; echo $jmode | sed 's/fail-first/fail,ok/' | tr , '\n' > $T/jmode
  # fake journalctl: records its arguments; one mode per call from the queue $T/jmode (the last one repeats; D167):
  # ok | fail (rc 1) | empty | nocdsp (no DSP lines); jmode=fail-first is "fail,ok"
  printf '#!/bin/bash\necho "$*" >> $T/jargs\nm=$(head -1 $T/jmode); [ $(wc -l < $T/jmode) -gt 1 ] && sed -i 1d $T/jmode\ncase $m in ok) cat $T/journal-ok.txt;; fail) echo "journal error" >&2; exit 1;; empty) :;; nocdsp) grep -v CDSP0 $T/journal-ok.txt;; esac\n' > $T/jc.sh; chmod +x $T/jc.sh
  env RUN_ROUTE=$T/run.sh RUN_V0E=$T/run.sh MEMFLOOR=$T/mem.py KAUDIT=$T/ka.sh PROBE_WAIT=0 SESS_PAUSE=0 CHECK_PROC=true \
      HTPR=$T/htpr FARF=$T/farf RETRY_SHA=$rs JOURNAL=$T/jc.sh GATE=$T/gate.sh PKGMAN=$T/pkgman PKGDIR=$T/pkg bash ~/v0/v0e_A_retry.sh $ARGS > $T/out.txt 2>&1; local rc=$?
  local seq=$(paste -sd' ' $T/calls 2>/dev/null) st=$BR/v0/v0d/v0e-$NAME-status.txt
  if [ $rc = $want_rc ] && [ "$seq" = "$want_seq" ]; then echo "ok   $name (rc $rc: $seq)"
  else echo "FAIL $name (rc $rc want $want_rc; seq '$seq' want '$want_seq')"; sed 's/^/     /' $T/out.txt | tail -8; fails=$((fails+1)); fi
  chk() { grep -q -- "$1" "$2" || { echo "FAIL $name: no '$1' in $(basename $2)"; fails=$((fails+1)); }; }
  case $name in
    retry-logged) chk "DSP v0e-$NAME-S1: logged retry events 1, longest run 1" $st;;
    retry-repeated) chk "FLAG v0e-$NAME-S1: repeated peek errors (3 in a row)" $st;;
    no-admission-stops) [ ! -s $T/gate-args ] || { echo "FAIL $name: gate ran"; fails=$((fails+1)); };;
    all-pass) chk "$BR/v0/v0d-admit-$SET $SET 1" $T/gate-args; chk "_PID=4242 _BOOT_ID=b00t1 --since 2026-10-11 10:00:00 --until 2026-10-11 10:31:00" $T/jargs
      # D157: the session server command and the memory cap of each set
      c=$(grep '^S1 ' $T/cmds); case $SET in AR) w="--cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"; cap=7942;;
        A32) w="--cache-ram 5120 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 32 --ctx-checkpoints 0"; cap=5120;; esac
      ncap=2; [ $ATT = 3 ] && ncap=3
      [[ "$c" == *"ADSP_LIBRARY_PATH=$T/farf;$T/htpr;"*" -c 32768 $w"* ]] && [ "$(sort -u $T/caps)" = $cap ] && [ "$(wc -l < $T/caps)" = $ncap ] \
        || { echo "FAIL $name: $SET session command or memfloor cap ($(sort -u $T/caps | paste -sd,)): $c"; fails=$((fails+1)); }
      chk "V0e $NAME: QUALIFIED at window 32768" $st
      # D161: the baseline probe command: release library (attempt 1, AR), patched library (A32 attempt 2); otherwise
      # the unchanged health check
      b=$(grep -m1 '^probe ' $T/cmds); case $ATT in 1) lib="ADSP_LIBRARY_PATH=$HOME/v0/hexpkg/pkg-linux/lib ";; 2|3|4|5) lib="ADSP_LIBRARY_PATH=$T/farf;$T/htpr;$HOME/v0/hexpkg/pkg-linux/lib ";; esac
      [[ "$b" == *"$lib"*"-c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"* ]] \
        && [ "$(grep -c '^probe ' $T/cmds)" = "$(grep -c "^probe .*$lib" $T/cmds)" ] || { echo "FAIL $name: baseline command: $b"; fails=$((fails+1)); }
      chk "attempt $ATT," $st
      chk "COST v0e-$NAME-S1: RESULT server-requests: 1 requests, prompt tokens 900, evaluated 900" $st
      chk "COST v0e-$NAME-S2: RESULT server-requests: 1 requests" $st
      # D167: attempt 3's S0 uses the default wording, S1 the neutral one after the rule; earlier attempts never set it
      if [ $ATT = 3 ]; then [ "$(grep -E '^(S0|S1) ' $T/wordings | paste -sd,)" = "S0 unset,S1 neutral" ] || { echo "FAIL $name: wordings $(paste -sd, $T/wordings)"; fails=$((fails+1)); }
        chk "S0 WORDING: current 2/8, neutral 8/8 -> S1 runs with the neutral cache wording" $st
      else grep -q neutral $T/wordings && { echo "FAIL $name: CACHE_WORDING set in attempt $ATT"; fails=$((fails+1)); }; fi;;
    recovery-probe-evidence-after-fault) chk "NOT QUALIFIED (faults recorded: 1, kept in faults.txt; recovery ended: probe probe-" $st;;
    s0-rule-stops) chk "STOP by the declared rule (neutral < 7/8)" $st;;
    s0-rule-boundary) chk "neutral 7/8 -> S1 runs with the neutral cache wording" $st;;
    journal-fail-hang-stands) chk "NOT QUALIFIED (fault HANG" $st;;
    s1-fail-names-the-set) chk "clean session): $NAME not qualified; S2 runs for evidence" $st;;
    id-change-after-baseline-loadfail-stops) chk "STOP: before baseline probe-" $st;;
    id-change-in-recovery-keeps-fault) chk "FAULT HANG in v0e-$NAME-S1" $st; chk "NOT QUALIFIED (faults recorded: 1" $st; chk "library identity lost before probe-" $st;;
    pkg-modified-stops) chk "STOP: before baseline probe-.*: the release package $T/pkg differs from $T/pkgman: FAIL lib/libllama.so.0.5.0: sha256 differs" $st;;
    pkg-missing-stops) chk "FAIL lib/libllama.so.0.5.0: missing" $st;;
    pkg-link-redirected-stops) chk "FAIL lib/libllama.so.0: links to ../bin/llama-server, expected libllama.so.0.5.0" $st;;
    pkg-extra-library-stops) chk "FAIL lib/libggml-extra.so: not in the manifest" $st;;
    pkg-changed-during-s1-stops) chk "STOP: the release package changed during v0e-$NAME-S1: the release package" $st;;
    hang-and-package-changed-keeps-fault) chk "STOP: the release package changed during v0e-$NAME-S1" $st; chk "FAULT HANG in v0e-$NAME-S1" $st; chk "NOT QUALIFIED (fault HANG in v0e-$NAME-S1; library identity lost)" $st;;
    pkg-not-checked-before-attempt-5) [ -e $BR/v0/v0e-$NAME/pkg-identity-last.txt ] && { echo "FAIL $name: the package was checked"; fails=$((fails+1)); };;
    hang-and-library-changed-keeps-fault) chk "STOP: the patched library or the .farf file changed during v0e-$NAME-S1" $st; chk "FAULT HANG in v0e-$NAME-S1" $st; chk "NOT QUALIFIED (fault HANG in v0e-$NAME-S1; library identity lost)" $st;;
  esac
  [ $name = all-pass ] && [ $ATT -ge 5 ] && chk "RESULT pkg-identity: PASS (2 files, 2 links, 0 external" $BR/v0/v0e-$NAME/pkg-identity-last.txt
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
# D161: attempt 2 checks the library before the first baseline (no probe runs); attempt 1 after it
LP="probe"; [ $ATT -ge 2 ] && LP=""
case1 wrong-library-stops 2 "$LP" RETRY_SHA=0000
case1 farf-changed-stops 2 "$LP" farf=0x0
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
# D138 (Codex review of 12be36a): only the latest, completed admission counts, and its gate is re-checked on the
# current evidence; a failed journal is excused only for a confirmed clean load failure
case1 admission-newer-fail-stops 6 "" admit-newer-fail
case1 admission-newer-unfinished-stops 6 "" admit-newer-unfinished
case1 admission-gate-recheck-fails-stops 6 "" gate-fail
case1 pass-without-ready-line-journal-fail-stops 2 "probe S1" mode-S1=pass-noready jmode=fail
case1 loadfail-journal-fail-recovers 0 "probe S1 probe probe S1 probe S2" mode-S1=loadfail,pass jmode=fail-first
# D157: an admission of the other set does not count
if [ $SET = A32 ]; then case1 a32-with-only-an-ar-admission-stops 6 "" other-set-admission; fi
# D161: the S1 item-failure line names the set
case1 s1-fail-names-the-set 1 "probe S1 probe S2" mode-S1=fail
# D162 (Codex review of 609552a): attempt 2 checks the identity immediately before EVERY baseline load (retries and
# recovery included); a fault already recorded stays recorded and the outcome NOT QUALIFIED. Any set: a session hang
# followed by a library change records the fault before stopping.
if [ $ATT -ge 2 ]; then
  case1 id-change-after-baseline-loadfail-stops 2 "probe" mode-probe=loadfail-farf
  case1 id-change-in-recovery-keeps-fault 3 "probe S1 probe" mode-S1=hang mode-probe=pass,loadfail-farf
fi
case1 hang-and-library-changed-keeps-fault 3 "probe S1" mode-S1=hang-farf
# D176 (attempt 5 on): the release package as built, before every baseline and session and after every session; a
# change after a recorded fault keeps the fault. Before attempt 5 the package is not checked (behaviour unchanged).
if [ $ATT -ge 5 ]; then
  case1 pkg-modified-stops 2 "" pkg=modified
  case1 pkg-missing-stops 2 "" pkg=missing
  case1 pkg-link-redirected-stops 2 "" pkg=redirect
  case1 pkg-extra-library-stops 2 "" pkg=extra
  case1 pkg-changed-during-s1-stops 2 "probe S1" mode-S1=pass-pkg
  case1 hang-and-package-changed-keeps-fault 3 "probe S1" mode-S1=hang-pkg
else
  case1 pkg-not-checked-before-attempt-5 0 "probe S1 probe S2" pkg=modified
fi
# D167, every set: a recovery probe that stops after a recorded fault keeps NOT QUALIFIED (exit 3); without a fault a
# stopping baseline is unchanged (exit 2)
case1 recovery-probe-evidence-after-fault 3 "probe S1 probe" mode-S1=hang mode-probe=pass,evidence
case1 baseline-evidence-without-fault-stops 2 "probe" mode-probe=evidence
# D167, attempt 3: the S0 rule (neutral >= 7/8) and S0's own outcomes
if [ $ATT = 3 ]; then
  case1 s0-rule-boundary 0 "probe S0 probe S1 probe S2" "wording=WORDING: current 8/8, neutral 7/8"
  case1 s0-rule-stops 4 "probe S0" "wording=WORDING: current 8/8, neutral 6/8"
  case1 s0-no-wording-line-stops 2 "probe S0" wording=none
  case1 s0-wrong-count-stops 2 "probe S0" "wording=WORDING: current 2/7, neutral 7/7"
  case1 s0-hang 3 "probe S0 probe" mode-S0=hang
  case1 s0-evidence-stops 2 "probe S0" mode-S0=evidence
  case1 s0-memreject 3 "probe S0" mem=reject-S0
  case1 s0-loadfail-once 0 "probe S0 probe probe S0 probe S1 probe S2" mode-S0=loadfail,pass
fi
echo "failures: $fails"; exit $fails
