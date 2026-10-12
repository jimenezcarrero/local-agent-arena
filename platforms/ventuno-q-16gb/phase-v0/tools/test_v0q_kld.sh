#!/bin/bash
# mocked tests for v0q_kld.sh (D146): a fake llama-perplexity; checks the CPU base, the per-arm env and the stops.
fails=0; T=$(mktemp -d)
cat > $T/ppl <<'F'
#!/bin/bash
echo "env OPFILTER=${GGML_HEXAGON_OPFILTER:-none} FUSION=${GGML_HEXAGON_OPFUSION:-none} MM=${GGML_HEXAGON_MM_SELECT:-none} FA=${GGML_HEXAGON_FA_SELECT:-none} args: $*" >> $T_LOG
kb=; p=; for x in "$@"; do [ "$p" = --kl-divergence-base ] && kb=$x; p=$x; done
case " $* " in *" --kl-divergence "*) [ "${GGML_HEXAGON_OPFILTER:-}" = BAD ] && exit 7
  [ "${GGML_HEXAGON_OPFILTER:-}" = CACHEOP ] && { echo "ggml-backend.cpp:1081: pre-allocated tensor (cache_r_l0) in a buffer (HTP0:0) that cannot run the operation (SCALE)"; exit 134; }
  if [ "${GGML_HEXAGON_OPFILTER:-}" = MAPFAIL ] || { [ "${GGML_HEXAGON_OPFILTER:-}" = MAPONCE ] && [ ! -e $T_LOG.once ]; }; then
    touch $T_LOG.once; echo "E ggml-hex: HTP0:1 buffer mapping failed : size 1 error 0x00000001"; exit 134; fi
  f=${GGML_HEXAGON_OPFILTER:-}; k=0.012345
  echo "W common_fit_params: failed to fit params to free device memory"  # a real warning that must not count as a failure
  [ "$f" = EMPTY ] && { echo "kl_divergence: failed reading log-probs for chunk 0"; exit 0; }
  [ "$f" = NAN ] && k=nan
  echo "kl_divergence: computing over 2 chunks, n_ctx=1024, batch_size=1024, n_seq=1"
  echo "   1       2.1355 ±    0.2074      -1.22279 ±    0.11164"
  [ "$f" = SHORT ] || echo "   2       2.1678 ±    0.1360      -1.29713 ±    0.08312"
  echo "Mean PPL(Q)                   :   9.200000 ±   0.100000"
  echo "Mean    KLD:   $k ±   0.000100"
  [ "$f" = NOTOP ] || echo "Same top p: 95.123 ± 0.500 %";;
 *) echo "perplexity: calculating perplexity over 2 chunks, n_ctx=1024, batch_size=1024, n_seq=1"
  [ "${MOCK_BASE:-}" = nofinal ] && { echo "[1]9.0000,"; exit 0; }
  echo "[1]9.0000,[2]9.1234,"; echo "Final estimate: PPL = 9.1234 +/- 0.1000"; [ "${MOCK_BASE:-}" = nofile ] || echo x > "$kb";; esac
F
chmod +x $T/ppl; export T_LOG=$T/log
ck() { [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: got '$2' want '$3'"; fails=$((fails+1)); }; }
PPL=$T/ppl ARMS="npu nofusion all MUL_MAT" bash ./v0q_kld.sh $T/o1 /dev/null > $T/out1 2>&1; ck "all arms pass rc" $? 0
ck "cpu base first, without the NPU" "$(head -1 $T_LOG | grep -c -- '--device none -ngl 0')" 1
ck "four NPU arms" "$(grep -c -- '--kl-divergence --\|--kl-divergence$' $T_LOG)" 4
ck "filters per arm" "$(grep -- '--kl-divergence$' $T_LOG | awk '{print $2,$3}' | paste -sd, -)" "OPFILTER=none FUSION=none,OPFILTER=none FUSION=0,OPFILTER=(?!(NONE|VIEW|RESHAPE|PERMUTE|TRANSPOSE)$).* FUSION=none,OPFILTER=MUL_MAT FUSION=none"
ck "summary lines" "$(grep -c '^arm .* rc 0 | Mean PPL(Q) : 9.200000 .*|Mean KLD: 0.012345 .*|Same top p: 95.123' $T/o1/summary.txt)" 4
: > $T_LOG; PPL=$T/ppl ARMS="npu BAD ROPE" bash ./v0q_kld.sh $T/o2 /dev/null > $T/out2 2>&1; ck "failing arm stops rc" $? 2
ck "no arm after the failure" "$(grep -c 'OPFILTER=ROPE' $T_LOG)" 0
PPL=$T/ppl ARMS=npu bash ./v0q_kld.sh $T/o1 /dev/null > /dev/null 2>&1; ck "existing output dir refused" $? 2
: > $T_LOG; PPL=$T/ppl ARMS="MAPONCE ROPE" bash ./v0q_kld.sh $T/o3 /dev/null > $T/out3 2>&1; ck "map failure reloaded once, then continues" "$?:$(grep -c 'OPFILTER=MAPONCE' $T_LOG):$(grep -c 'OPFILTER=ROPE' $T_LOG)" "0:2:1"
ck "load failure kept" "$(ls $T/o3 | grep -c loadfail)" 1
: > $T_LOG; PPL=$T/ppl ARMS="MAPFAIL ROPE" bash ./v0q_kld.sh $T/o4 /dev/null > $T/out4 2>&1; ck "second map failure stops" "$?:$(grep -c 'OPFILTER=MAPFAIL' $T_LOG):$(grep -c 'OPFILTER=ROPE' $T_LOG)" "2:2:0"
: > $T_LOG; PPL=$T/ppl ARMS="CACHEOP ROPE" bash ./v0q_kld.sh $T/o5 /dev/null > $T/out5 2>&1; ck "scheduler refusal: not runnable, next arm runs" "$?:$(grep -c 'NOT RUNNABLE' $T/o5/summary.txt):$(grep -c 'OPFILTER=ROPE' $T_LOG)" "0:1:1"
: > $T_LOG; DEVS=HTP0:0 PPL=$T/ppl ARMS="npu" bash ./v0q_kld.sh $T/o6 /dev/null > /dev/null 2>&1; ck "DEVS=HTP0:0: one session" "$?:$(grep -c -- '--device HTP0:0 -ngl 99' $T_LOG)" "0:1"
: > $T_LOG; PPL=$T/ppl ARMS="env:GGML_HEXAGON_MM_SELECT=1 env:GGML_HEXAGON_MM_SELECT=1,GGML_HEXAGON_FA_SELECT=1" bash ./v0q_kld.sh $T/o7 /dev/null > /dev/null 2>&1; ck "env arms set selectors, no filter" "$?:$(grep -- '--kl-divergence$' $T_LOG | awk '{print $2,$4,$5}' | paste -sd, -)" "0:OPFILTER=none MM=1 FA=none,OPFILTER=none MM=1 FA=1"
: > $T_LOG; PPL=$T/ppl ARMS="args:-ub,1 npu" bash ./v0q_kld.sh $T/o8 /dev/null > /dev/null 2>&1; ck "args arm appends flags, next arm without them" "$?:$(grep -c -- '-ngl 99 -ub 1 --kl-divergence-base' $T_LOG):$(grep -- '--kl-divergence$' $T_LOG | grep -c -- '-ngl 99 --kl-divergence-base')" "0:1:1"
# D156: rc 0 without complete measurements stops
: > $T_LOG; MOCK_BASE=nofinal PPL=$T/ppl ARMS=npu bash ./v0q_kld.sh $T/o9 /dev/null > /dev/null 2>&1; ck "base without final PPL stops, no arm" "$?:$(grep -c -- '--kl-divergence$' $T_LOG):$(grep -c 'running PPL of chunk 2 missing' $T/o9/summary.txt)" "1:0:1"
: > $T_LOG; MOCK_BASE=nofile PPL=$T/ppl ARMS=npu bash ./v0q_kld.sh $T/o10 /dev/null > /dev/null 2>&1; ck "base without logits file stops, no arm" "$?:$(grep -c -- '--kl-divergence$' $T_LOG):$(grep -c 'logits file missing' $T/o10/summary.txt)" "1:0:1"
: > $T_LOG; PPL=$T/ppl ARMS="EMPTY ROPE" bash ./v0q_kld.sh $T/o11 /dev/null > /dev/null 2>&1; ck "kl_divergence read failure with rc 0 stops, log kept" "$?:$(grep -c 'OPFILTER=ROPE' $T_LOG):$(grep -c 'failed reading log-probs' $T/o11/summary.txt):$(grep -c 'failed reading' $T/o11/arm01.log)" "4:0:1:1"
for c in NAN:"no finite Mean KLD" SHORT:"not 2 chunk rows" NOTOP:"no finite Same top p"; do
  : > $T_LOG; PPL=$T/ppl ARMS="${c%%:*} ROPE" bash ./v0q_kld.sh $T/o-${c%%:*} /dev/null > /dev/null 2>&1
  ck "${c%%:*}: incomplete arm stops" "$?:$(grep -c 'OPFILTER=ROPE' $T_LOG):$(grep -c "${c#*:}" $T/o-${c%%:*}/summary.txt)" "4:0:1"; done
rm -rf $T; echo "failures: $fails"; exit $fails
