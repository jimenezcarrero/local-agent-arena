#!/bin/bash
# tests for b1e_tensor_diff.py on synthetic eval-callback dumps in the ff5a2337 format (common/debug.cpp), including the
# fail-closed cases of the review of 67dab16 (missing sums, missing result_output, NaN, bad options, extras)
D=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); fails=0
hdr() { printf 'common_debug_cb_eval: %24s = (%s) %10s(%s{%s}, }) = {%s}\n' "$1" "$2" "$3" src "1, 1, 1, 1" "$4"; }
# blk <name> <op> <shape> <sum> [values, default "0.1000, 0.2000"]
blk() { hdr "$1" f32 "$2" "$3"; printf '    [\n        [\n            [%s  ],\n        ],\n    ]\n    sum = %s\n' "${5:-      0.1000,       0.2000}" "$4"; }
mk() { local f=$1; shift; : > $f; while [ $# -gt 0 ]; do blk "$1" "$2" "$3" "$4" >> $f; shift 4; done; }
case1() { local name=$1 want=$2 pat=$3; shift 3
  out=$(python3 -I $D/b1e_tensor_diff.py "$@" 2>&1); rc=$?
  if [ $rc = $want ] && grep -q -- "$pat" <<<"$out"; then echo "ok   $name"; else echo "FAIL $name (rc $rc want $want, /$pat/)"; sed 's/^/     /' <<<"$out"; fails=$((fails+1)); fi; }
R="248320, 1, 1, 1"; S="2560, 5, 1, 1"
mk $T/a inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" 3.25  l_out-0 ADD "$S" -7.0  result_output MUL_MAT "$R" 100.0
cp $T/a $T/same
mk $T/tiny inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" 3.2501  l_out-0 ADD "$S" -7.0  result_output MUL_MAT "$R" 100.0
mk $T/mid inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" 3.4  l_out-0 ADD "$S" -900.0  result_output MUL_MAT "$R" 9.0
mk $T/shape inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "2560, 4, 1, 1" 3.25  l_out-0 ADD "$S" -7.0  result_output MUL_MAT "$R" 100.0
mk $T/nan inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" nan  l_out-0 ADD "$S" -7.0  result_output MUL_MAT "$R" 100.0
# B with a second session's copy node and noise lines from other loggers, otherwise equal
{ echo "0.11.128.027 D ## SPLIT #2: HTP0:0 # 6 inputs"; blk inp_embd GET_ROWS "$S" 1.5; blk "HTP0:1#node_0" CPY "$S" 1.5; echo "sched debug noise sum = 99"; blk norm-0 RMS_NORM "$S" 3.25; blk l_out-0 ADD "$S" -7.0; blk result_output MUL_MAT "$R" 100.0; } > $T/copy
# B with an extra logical tensor (not a session copy)
{ cat $T/a; blk extra-node ADD "$S" 1.0; } > $T/extra
# repeated names: the second occurrence differs
mk $T/rep1 node_3 MUL_MAT "64, 1, 1, 1" 1.0  node_3 MUL_MAT "64, 1, 1, 1" 2.0  result_output MUL_MAT "$R" 1.0
mk $T/rep2 node_3 MUL_MAT "64, 1, 1, 1" 1.0  node_3 MUL_MAT "64, 1, 1, 1" 5.0  result_output MUL_MAT "$R" 1.0
# quantized tensor: header, no sum
{ hdr blk.0.w q2_0 GET_ROWS "64, 1, 1, 1"; blk result_output MUL_MAT "8, 1, 1, 1" 1.0; } > $T/q
# same sums, permuted samples ([1,2] vs [2,1]): the samples differ
{ blk result_output MUL_MAT "2, 1, 1, 1" 3.0 "      1.0000,       2.0000"; } > $T/p1
{ blk result_output MUL_MAT "2, 1, 1, 1" 3.0 "      2.0000,       1.0000"; } > $T/p2
# fail-closed fixtures
{ hdr x f32 ADD "$S"; hdr result_output f32 MUL_MAT "$R"; } > $T/nosums
mk $T/noout inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" 3.25
mk $T/bothnan1 result_output MUL_MAT "$R" nan
cp $T/bothnan1 $T/bothnan2
mk $T/short inp_embd GET_ROWS "$S" 1.5  result_output MUL_MAT "$R" 100.0
case1 same 0 "RESULT SAME (4 compared, maxrel 0.0)" $T/a $T/same
case1 tiny-within-tolerance 0 "RESULT SAME" $T/a $T/tiny
case1 maxrel-full-precision 0 "MAXREL 3.07" $T/a $T/tiny
case1 tiny-strict-tolerance 1 "FIRST norm-0#1 op=RMS_NORM" $T/a $T/tiny --rel 1e-6
case1 first-and-gross 1 "GROSS l_out-0#1 op=ADD" $T/a $T/mid
case1 first-is-norm 1 "RESULT DIFFER first=norm-0#1 op=RMS_NORM" $T/a $T/mid
case1 gross-independent-of-rel 1 "GROSS l_out-0#1" $T/a $T/mid --rel 0.5
case1 shape-differs 1 "FIRST norm-0#1" $T/a $T/shape
case1 copy-node-same 0 "RESULT SAME (4 compared" $T/a $T/copy
case1 copy-node-listed 0 "session copies: 1" $T/a $T/copy
case1 extra-logical-in-B 3 "not session copies, first extra-node#1" $T/a $T/extra
case1 missing-in-B 3 "2 key(s) of A missing from B, first norm-0#1" $T/a $T/short
case1 repeated-name-occurrence 1 "FIRST node_3#2" $T/rep1 $T/rep2
case1 quantized-skipped 0 "RESULT SAME (1 compared" $T/q $T/q
case1 permuted-samples-differ 1 "FIRST result_output#1" $T/p1 $T/p2
case1 nan-one-side 3 "non-finite" $T/a $T/nan
case1 nan-both-sides 3 "non-finite" $T/bothnan1 $T/bothnan2
case1 headers-without-sums 3 "has no sum" $T/nosums $T/nosums
case1 result-output-missing 3 "required tensor result_output missing from B" $T/a $T/noout
case1 required-missing-both 3 "required tensor result_output missing from A" $T/noout $T/noout
case1 rel-nan 3 "--rel nan is not finite" $T/a $T/mid --rel nan
case1 rel-zero 3 "--rel 0.0 is not finite" $T/a $T/a --rel 0
case1 gross-inf 3 "--gross inf is not finite" $T/a $T/a --gross inf
: > $T/empty
case1 empty-dump 3 "missing from B" $T/a $T/empty
case1 usage 2 "" $T/a
rm -rf $T; echo "failures: $fails"; exit $fails
