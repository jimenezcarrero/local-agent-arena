#!/bin/bash
# mocked tests for v0q_kld.sh (D146): a fake llama-perplexity; checks the CPU base, the per-arm env and the stops.
fails=0; T=$(mktemp -d)
cat > $T/ppl <<'F'
#!/bin/bash
echo "env OPFILTER=${GGML_HEXAGON_OPFILTER:-none} FUSION=${GGML_HEXAGON_OPFUSION:-none} args: $*" >> $T_LOG
case " $* " in *" --kl-divergence "*) [ "${GGML_HEXAGON_OPFILTER:-}" = BAD ] && exit 7
  printf "Mean    KLD:   0.012345 ±   0.000100\nSame top p: 95.123 ± 0.500 %%\n";; *) echo "Final estimate: PPL = 9.1234 +/- 0.1000";; esac
F
chmod +x $T/ppl; export T_LOG=$T/log
ck() { [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: got '$2' want '$3'"; fails=$((fails+1)); }; }
PPL=$T/ppl ARMS="npu nofusion all MUL_MAT" bash ./v0q_kld.sh $T/o1 /dev/null > $T/out1 2>&1; ck "all arms pass rc" $? 0
ck "cpu base first, without the NPU" "$(head -1 $T_LOG | grep -c -- '--device none -ngl 0')" 1
ck "four NPU arms" "$(grep -c -- '--kl-divergence --\|--kl-divergence$' $T_LOG)" 4
ck "filters per arm" "$(grep -- '--kl-divergence$' $T_LOG | awk '{print $2,$3}' | paste -sd, -)" "OPFILTER=none FUSION=none,OPFILTER=none FUSION=0,OPFILTER=.* FUSION=none,OPFILTER=MUL_MAT FUSION=none"
ck "summary lines" "$(grep -c '^arm .* rc 0 | Mean KLD: 0.012345' $T/o1/summary.txt)" 4
: > $T_LOG; PPL=$T/ppl ARMS="npu BAD ROPE" bash ./v0q_kld.sh $T/o2 /dev/null > $T/out2 2>&1; ck "failing arm stops rc" $? 2
ck "no arm after the failure" "$(grep -c 'OPFILTER=ROPE' $T_LOG)" 0
PPL=$T/ppl ARMS=npu bash ./v0q_kld.sh $T/o1 /dev/null > /dev/null 2>&1; ck "existing output dir refused" $? 2
rm -rf $T; echo "failures: $fails"; exit $fails
