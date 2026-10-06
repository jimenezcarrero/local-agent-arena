#!/bin/bash
# synthetic tests for v0d_lib.sh classify(), including mixed conditions (Codex review 2026-10-06 08:38Z)
T=$(mktemp -d); export WD_LOG=$T/wd.txt; echo "x" > $WD_LOG; source ~/v0/v0d_lib.sh; fails=0
mk() { rm -rf $T/$1; mkdir -p $T/$1; printf "%s\n" "$2" > $T/$1/run.txt; [ -n "$3" ] && printf "%s\n" "$3" > $T/$1/health-verdict.txt; [ -n "$4" ] && printf "%s\n" "$4" > $T/$1/server.log; true; }
chk() { local got; got=$(classify $T/$1 $2 0); [ "$got" = "$3" ] && echo "ok   $1 rc=$2 -> $got" || { echo "FAIL $1 rc=$2 -> $got (want $3)"; fails=$((fails+1)); }; }
MAP="E ggml-hex: HTP0:0 buffer mapping failed : domain_id 3 size 671092736"
LF="t SERVER EXITED before ready (see server.log)"
mk pass "t RESULT PASS (speed, health: pass, kernel evidence)" "pass"; chk pass 0 PASS
mk pass-psi "t RESULT PASS (speed, health: pass (PSI-only alerts exempt))" "pass (PSI-only alerts exempt)"; chk pass-psi 0 PASS
mk rc-nonzero "t RESULT PASS" "pass"; chk rc-nonzero 1 EVIDENCE
mk timeout "t START" ""; chk timeout 124 EVIDENCE
mk no-verdict "t RESULT PASS" ""; chk no-verdict 0 EVIDENCE
mk health-fail "t RESULT FAIL: health=(fail: ALERT swap used)" "fail: ALERT swap used"; chk health-fail 1 EVIDENCE
mk loadfail "$LF
t RESULT FAIL: speed=4" "pass" "$MAP"; chk loadfail 1 LOADFAIL
mk exit-nomap "$LF
t RESULT FAIL: speed=4" "pass" "segfault"; chk exit-nomap 1 EVIDENCE
mk speedfail "t RESULT FAIL: speed=1" "pass"; chk speedfail 1 EVIDENCE
# mixed: load-failure strings present, but other evidence missing or failed
mk lf-noverdict "$LF
t RESULT FAIL: speed=4" "" "$MAP"; chk lf-noverdict 1 EVIDENCE
mk lf-oom "$LF
t RESULT FAIL: speed=4 health=(fail: ALERT OOM kill)" "fail: ALERT OOM kill" "$MAP"; chk lf-oom 1 EVIDENCE
mk lf-timeout "$LF" "pass" "$MAP"; chk lf-timeout 124 EVIDENCE
mk lf-kernel "$LF
t RESULT FAIL: speed=4 kernel_read_after_end=TIMEOUT" "pass" "$MAP"; chk lf-kernel 1 EVIDENCE
mk lf-noresult "$LF" "pass" "$MAP"; chk lf-noresult 1 EVIDENCE
mk lf-crash "$LF
t RESULT FAIL: speed=4" "pass" "$MAP"; chk lf-crash 2 EVIDENCE
echo "y NPU-WATCHDOG killed" >> $WD_LOG; chk pass 0 HANG
rm -rf $T; echo "failures: $fails"; exit $fails
