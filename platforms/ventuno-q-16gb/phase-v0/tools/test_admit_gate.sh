#!/bin/bash
# tests for admit_gate.py (D137): the published D90 sets reproduce their medians; synthetic sets for each failure branch.
G=${G:-$(dirname "$0")/admit_gate.py}; R=${R:-$(dirname "$0")/../runs}; fails=0
t() { local name=$1 want=$2; shift 2; out=$(python3 $G "$@"); rc=$?
  [ $rc = $want ] && echo "ok   $name (rc $rc): ${out:0:90}" || { echo "FAIL $name (rc $rc want $want): $out"; fails=$((fails+1)); }; }
t published-A 0 $R/v0d-admit-A A 1
t published-AM 0 $R/v0d-admit-AM AM 1
t published-H-r3-missing 2 $R/v0d-admit-H H 1
T=$(mktemp -d)
mk() { local r=$1 line=$2; mkdir -p $T/X-s1-r$r; printf '%s\n' "$line" > $T/X-s1-r$r/probe.txt; }
L() { echo "RESULT X-s1-r$1: depth=16384 prompt_tokens=$2 ttft=1s prefill_tps=$3 gen_tokens=128 decode_tps=$4 method=usage"; }
mk 1 "$(L 1 18000 300 8)"; mk 2 "$(L 2 18000 140 8)"; mk 3 "$(L 3 18000 140 8)"; t median-prefill-below 3 $T X 1
mk 2 "$(L 2 18000 300 4.3)"; mk 3 "$(L 3 18000 300 4.3)"; t median-decode-below 3 $T X 1
mk 2 "$(L 2 18000 300 8)"; mk 3 "$(L 3 18000 300 8)"; t synthetic-pass 0 $T X 1
mk 3 "$(L 3 20000 300 8)"; t prompt-off-depth 2 $T X 1
mk 3 "RETRY X-s1-r3: depth=16384 prompt_tokens=18000 prefill_tps=300 decode_tps=8 OFF_DEPTH"; t retry-line-only 2 $T X 1
mk 3 "$(L 3 18000 300 8)
$(L 3 18000 300 8)"; t duplicate-result 2 $T X 1
mk 3 "$(L 3 18000 abc 8)"; t non-numeric 2 $T X 1
rm -rf $T; echo "failures: $fails"; exit $fails
