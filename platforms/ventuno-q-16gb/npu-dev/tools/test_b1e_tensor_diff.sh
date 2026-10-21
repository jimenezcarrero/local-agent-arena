#!/bin/bash
# tests for b1e_tensor_diff.py on synthetic eval-callback dumps in the ff5a2337 format (common/debug.cpp)
D=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); fails=0
hdr() { printf 'common_debug_cb_eval: %24s = (%s) %10s(%s{%s}, }) = {%s}\n' "$1" "$2" "$3" src "1, 1, 1, 1" "$4"; }
blk() { hdr "$1" f32 "$2" "$3"; printf '    [\n        [\n            [      0.1000,       0.2000  ],\n        ],\n    ]\n    sum = %s\n' "$4"; }
mk() { local f=$1; shift; : > $f; while [ $# -gt 0 ]; do blk "$1" "$2" "$3" "$4" >> $f; shift 4; done; }
case1() { local name=$1 want=$2 pat=$3; shift 3
  out=$(python3 -I $D/b1e_tensor_diff.py "$@" 2>&1); rc=$?
  if [ $rc = $want ] && grep -q -- "$pat" <<<"$out"; then echo "ok   $name"; else echo "FAIL $name (rc $rc want $want, /$pat/)"; sed 's/^/     /' <<<"$out"; fails=$((fails+1)); fi; }
mk $T/a inp_embd GET_ROWS "2560, 5, 1, 1" 1.5  norm-0 RMS_NORM "2560, 5, 1, 1" 3.25  l_out-0 ADD "2560, 5, 1, 1" -7.0  result_output MUL_MAT "248320, 1, 1, 1" 100.0
cp $T/a $T/same
mk $T/tiny inp_embd GET_ROWS "2560, 5, 1, 1" 1.5  norm-0 RMS_NORM "2560, 5, 1, 1" 3.2501  l_out-0 ADD "2560, 5, 1, 1" -7.0  result_output MUL_MAT "248320, 1, 1, 1" 100.0
mk $T/mid inp_embd GET_ROWS "2560, 5, 1, 1" 1.5  norm-0 RMS_NORM "2560, 5, 1, 1" 3.4  l_out-0 ADD "2560, 5, 1, 1" -900.0  result_output MUL_MAT "248320, 1, 1, 1" 9.0
mk $T/shape inp_embd GET_ROWS "2560, 5, 1, 1" 1.5  norm-0 RMS_NORM "2560, 4, 1, 1" 3.25  l_out-0 ADD "2560, 5, 1, 1" -7.0  result_output MUL_MAT "248320, 1, 1, 1" 100.0
mk $T/nan inp_embd GET_ROWS "2560, 5, 1, 1" 1.5  norm-0 RMS_NORM "2560, 5, 1, 1" nan  l_out-0 ADD "2560, 5, 1, 1" -7.0  result_output MUL_MAT "248320, 1, 1, 1" 100.0
# B with a second session's copy node and noise lines from other loggers, otherwise equal
{ echo "0.11.128.027 D ## SPLIT #2: HTP0:0 # 6 inputs"; blk inp_embd GET_ROWS "2560, 5, 1, 1" 1.5; blk "HTP0:1#node_0" CPY "2560, 5, 1, 1" 1.5; echo "sched debug noise sum = 99"; blk norm-0 RMS_NORM "2560, 5, 1, 1" 3.25; blk l_out-0 ADD "2560, 5, 1, 1" -7.0; blk result_output MUL_MAT "248320, 1, 1, 1" 100.0; } > $T/copy
# repeated names: the second occurrence differs
mk $T/rep1 node_3 MUL_MAT "64, 1, 1, 1" 1.0  node_3 MUL_MAT "64, 1, 1, 1" 2.0
mk $T/rep2 node_3 MUL_MAT "64, 1, 1, 1" 1.0  node_3 MUL_MAT "64, 1, 1, 1" 5.0
# quantized tensor: header, no sum
{ hdr blk.0.w q2_0 GET_ROWS "64, 1, 1, 1"; blk norm-0 RMS_NORM "8, 1, 1, 1" 1.0; } > $T/q
case1 same 0 "RESULT SAME (4 compared)" $T/a $T/same
case1 tiny-within-tolerance 0 "RESULT SAME" $T/a $T/tiny
case1 tiny-strict-tolerance 1 "FIRST norm-0#1 op=RMS_NORM" $T/a $T/tiny --rel 1e-6
case1 first-and-gross 1 "GROSS l_out-0#1 op=ADD" $T/a $T/mid
case1 first-is-norm 1 "RESULT DIFFER first=norm-0#1 op=RMS_NORM" $T/a $T/mid
case1 shape-differs 1 "FIRST norm-0#1" $T/a $T/shape
case1 nan-one-side 1 "FIRST norm-0#1" $T/a $T/nan
case1 copy-node-listed-not-compared 0 "only in B 1" $T/a $T/copy
case1 copy-node-same 0 "RESULT SAME (4 compared)" $T/a $T/copy
case1 repeated-name-occurrence 1 "FIRST node_3#2" $T/rep1 $T/rep2
case1 quantized-skipped 0 "RESULT SAME (1 compared)" $T/q $T/q
: > $T/empty
case1 empty-dump 2 "no tensors in B" $T/a $T/empty
case1 usage 2 "" $T/a
rm -rf $T; echo "failures: $fails"; exit $fails
