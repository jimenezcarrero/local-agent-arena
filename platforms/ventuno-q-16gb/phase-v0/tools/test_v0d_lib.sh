#!/bin/bash
# synthetic tests for v0d_lib.sh classify(), including mixed conditions (Codex review 2026-10-06 08:38Z)
T=$(mktemp -d); export WD_LOG=$T/wd.txt
# fake kernel audit: <run dir>/kaudit holds "<verdict line>|<exit code>" (default: clean); kernel_audit.py itself is
# tested in test_kernel_audit.sh
cat > $T/kaudit.sh <<'K'
#!/bin/bash
v="pass|0"; [ -f "$1/kaudit" ] && v=$(cat "$1/kaudit"); echo "${v%|*}"; exit "${v#*|}"
K
chmod +x $T/kaudit.sh; export KAUDIT=$T/kaudit.sh; echo "x" > $WD_LOG; source ~/v0/v0d_lib.sh; fails=0
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
mk devfault "t RESULT FAIL: speed=1" "pass" "/w/ggml-hexagon.cpp:4036: ggml-hex: dspqueue_read failed: 0x0000002e
#2 0x0 in ggml_abort () from libggml-base.so.0"; chk devfault 1 DEVFAULT
mk devfault-atload "$LF
t RESULT FAIL: speed=4" "pass" "E ggml-hex: HTP0:0 buffer mapping failed : domain_id 3 size 1
terminate called after throwing an instance of 'std::runtime_error'
  what():  ggml-hex: fastrpc_mmap failed"; chk devfault-atload 1 LOADFAIL
# kernel audit (Codex review 20:32Z finding 1): faults fail independently of a passing speed probe
mk k-gpufault "t RESULT PASS (speed, health: pass, kernel evidence)" "pass"; echo "fault fault=23|1" > $T/k-gpufault/kaudit; chk k-gpufault 0 DEVFAULT
mk k-unknown "t RESULT PASS (speed, health: pass, kernel evidence)" "pass"; echo "unknown unknown=1|2" > $T/k-unknown/kaudit; chk k-unknown 0 EVIDENCE
mk k-missing "t RESULT PASS (speed, health: pass, kernel evidence)" "pass"; echo "missing: no kernel journal copy|3" > $T/k-missing/kaudit; chk k-missing 0 EVIDENCE
mk k-map-pass "t RESULT PASS (speed, health: pass, kernel evidence)" "pass"; echo "npu_map npu_map=1|0" > $T/k-map-pass/kaudit; chk k-map-pass 0 EVIDENCE
mk k-map-load "$LF
t RESULT FAIL: speed=4" "pass" "$MAP"; echo "npu_map npu_map=1|0" > $T/k-map-load/kaudit; chk k-map-load 1 LOADFAIL
mk k-fault-load "$LF
t RESULT FAIL: speed=4" "pass" "$MAP"; echo "fault fault=1 npu_map=1|1" > $T/k-fault-load/kaudit; chk k-fault-load 1 DEVFAULT
echo "y NPU-WATCHDOG killed" >> $WD_LOG; chk pass 0 HANG
rm -rf $T; echo "failures: $fails"; exit $fails
