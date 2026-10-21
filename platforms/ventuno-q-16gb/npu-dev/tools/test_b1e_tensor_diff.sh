#!/bin/bash
# tests for b1e_tensor_diff.py on synthetic eval-callback dumps in the ff5a2337 format (common/debug.cpp), including the
# fail-closed cases of the reviews of 67dab16 and f827e4c (missing sums, missing result_output, NaN, bad options, extras,
# sample coverage per shape, ne3 > 1 slices, GROSS before SAME). Every fixture's printed sample matches its shape.
D=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); fails=0
hdr() { printf 'common_debug_cb_eval: %24s = (%s) %10s(%s{%s}, }) = {%s}\n' "$1" "$2" "$3" src "1, 1, 1, 1" "$4"; }
# blk <name> <op> <shape> <sum> [values of one slice, default "0.1000, 0.2000"]: one printed slice per ne3 (the values
# repeated), each followed by the total sum, as debug.cpp prints; slice <name> <op> <shape> <sum> <values 1> <values 2>
# prints two slices with different values (ne3 = 2)
one() { printf '    [\n        [\n            [%s  ],\n        ],\n    ]\n    sum = %s\n' "$1" "$2"; }
blk() { local n3; hdr "$1" f32 "$2" "$3"; n3=${3##*, }; for i in $(seq 1 $n3); do one "${5:-      0.1000,       0.2000}" "$4"; done; }
slice() { hdr "$1" f32 "$2" "$3"; one "$5" "$4"; one "$6" "$4"; }
mk() { local f=$1; shift; : > $f; while [ $# -gt 0 ]; do blk "$1" "$2" "$3" "$4" >> $f; shift 4; done; }
case1() { local name=$1 want=$2 pat=$3; shift 3
  out=$(python3 -I $D/b1e_tensor_diff.py "$@" 2>&1); rc=$?
  if [ $rc = $want ] && grep -q -- "$pat" <<<"$out"; then echo "ok   $name"; else echo "FAIL $name (rc $rc want $want, /$pat/)"; sed 's/^/     /' <<<"$out"; fails=$((fails+1)); fi; }
R="2, 1, 1, 1"; S="2, 1, 1, 1"
mk $T/a inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" 3.25  l_out-0 ADD "$S" -7.0  result_output MUL_MAT "$R" 100.0
cp $T/a $T/same
mk $T/tiny inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" 3.2501  l_out-0 ADD "$S" -7.0  result_output MUL_MAT "$R" 100.0
mk $T/mid inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" 3.4  l_out-0 ADD "$S" -900.0  result_output MUL_MAT "$R" 9.0
mk $T/shape inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "1, 2, 1, 1" 3.25  l_out-0 ADD "$S" -7.0  result_output MUL_MAT "$R" 100.0
mk $T/nan inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" nan  l_out-0 ADD "$S" -7.0  result_output MUL_MAT "$R" 100.0
# B with a second session's copy node and noise lines from other loggers, otherwise equal
{ echo "0.11.128.027 D ## SPLIT #2: HTP0:0 # 6 inputs"; blk inp_embd GET_ROWS "$S" 1.5; blk "HTP0:1#node_0" CPY "$S" 1.5; echo "sched debug noise sum = 99"; blk norm-0 RMS_NORM "$S" 3.25; blk l_out-0 ADD "$S" -7.0; blk result_output MUL_MAT "$R" 100.0; } > $T/copy
# B with an extra logical tensor (not a session copy)
{ cat $T/a; blk extra-node ADD "$S" 1.0; } > $T/extra
# repeated names: the second occurrence differs
mk $T/rep1 node_3 MUL_MAT "$S" 1.0  node_3 MUL_MAT "$S" 2.0  result_output MUL_MAT "$R" 1.0
mk $T/rep2 node_3 MUL_MAT "$S" 1.0  node_3 MUL_MAT "$S" 5.0  result_output MUL_MAT "$R" 1.0
# quantized tensor: header, no sum
{ hdr blk.0.w q2_0 GET_ROWS "64, 1, 1, 1"; blk result_output MUL_MAT "$R" 1.0; } > $T/q
# same sums, permuted samples ([1,2] vs [2,1]): the samples differ
{ blk result_output MUL_MAT "2, 1, 1, 1" 3.0 "      1.0000,       2.0000"; } > $T/p1
{ blk result_output MUL_MAT "2, 1, 1, 1" 3.0 "      2.0000,       1.0000"; } > $T/p2
# fail-closed fixtures
{ hdr x f32 ADD "$S"; hdr result_output f32 MUL_MAT "$R"; } > $T/nosums
mk $T/noout inp_embd GET_ROWS "$S" 1.5  norm-0 RMS_NORM "$S" 3.25
mk $T/bothnan1 result_output MUL_MAT "$R" nan
cp $T/bothnan1 $T/bothnan2
mk $T/short inp_embd GET_ROWS "$S" 1.5  result_output MUL_MAT "$R" 100.0
# ne3 = 2: the second slice's values permuted only (review of f827e4c)
{ slice result_output MUL_MAT "2, 1, 1, 2" 6.0 "      1.0000,       2.0000" "      1.0000,       2.0000"; } > $T/n3a
{ slice result_output MUL_MAT "2, 1, 1, 2" 6.0 "      1.0000,       2.0000" "      2.0000,       1.0000"; } > $T/n3b
# ne3 = 2 with only one slice printed; sample rows missing; a truncated sample; a large shape sampled 6 x 6
{ hdr result_output f32 MUL_MAT "2, 1, 1, 2"; one "      1.0000,       2.0000" 6.0; } > $T/n3short
{ hdr result_output f32 MUL_MAT "2, 1, 1, 1"; echo "    sum = 3.000000"; } > $T/norows
{ blk result_output MUL_MAT "3, 1, 1, 1" 3.0 "      1.0000,       2.0000"; } > $T/trunc
V6="      1.0000,       1.0000,       1.0000,    ...,       1.0000,       1.0000,       1.0000"
{ hdr result_output f32 MUL_MAT "4096, 1, 1, 1"; one "$V6" 4096.0; } > $T/big
# GROSS reported with a SAME result (rel above the difference, gross below it)
mk $T/g1 result_output MUL_MAT "$R" 7.0
mk $T/g2 result_output MUL_MAT "$R" 8.0
case1 same 0 "RESULT SAME (4 compared, maxrel 0.0)" $T/a $T/same
case1 tiny-within-tolerance 0 "RESULT SAME" $T/a $T/tiny
case1 maxrel-full-precision 0 "MAXREL 3.07" $T/a $T/tiny
case1 ne3-second-slice-differs 1 "FIRST result_output#1" $T/n3a $T/n3b
case1 ne3-same 0 "RESULT SAME (1 compared" $T/n3a $T/n3a
case1 ne3-one-slice-missing 3 "1 sum line(s), expected 2 (ne3)" $T/n3short $T/n3short
case1 sample-rows-missing 3 "0 sample value(s), expected 2" $T/norows $T/norows
case1 sample-truncated 3 "2 sample value(s), expected 3" $T/trunc $T/trunc
case1 large-shape-sampled 0 "RESULT SAME (1 compared" $T/big $T/big
case1 gross-before-same 0 "GROSS result_output#1 op=MUL_MAT" $T/g1 $T/g2 --rel 0.5
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
