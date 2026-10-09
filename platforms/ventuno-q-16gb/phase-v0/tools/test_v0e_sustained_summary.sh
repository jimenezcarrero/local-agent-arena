#!/bin/bash
# offline tests for v0e_sustained_summary.py (D117): synthetic cycles.tsv, speed-c<n>.txt and health rows in a temp dir.
S=$(dirname "$(readlink -f "$0")")/v0e_sustained_summary.py; fails=0
mk() { # mk <cycles> <late prefill> [nospeed=<n>] [notemp=<n>]
  T=$(mktemp -d); mkdir $T/mon; local i t0
  for i in $(seq 1 $1); do t0=$((1000000 + i*300)); echo "$i $t0 $((t0+250))" >> $T/cycles.tsv
    p=300.0; [ $i -gt 3 ] && p=$2
    [ "$3" = nospeed=$i ] || echo "RESULT x-c$i: depth=8192 prompt_tokens=7581 ttft=24.7s prefill_tps=$p gen_tokens=128 decode_tps=8.10 method=usage" > $T/speed-c$i.txt
    [ "$3" = notemp=$i ] || echo "{\"epoch\": $((t0+100)), \"temp_mC\": {\"nsp-0-0-0-thermal\": 61000, \"cpu-0-0-0-thermal\": 55000, \"ddrss-0-thermal\": 50000}}" >> $T/mon/health-x.jsonl
  done; }
case1() { local name=$1 want_rc=$2 want=$3; shift 3; mk "$@"
  out=$(python3 $S $T $T/mon); rc=$?; last=$(echo "$out" | tail -1)
  if [ $rc = $want_rc ] && [[ "$last" == *"$want"* ]]; then echo "ok   $name: $last"; else echo "FAIL $name (rc $rc): $last"; fails=$((fails+1)); fi
  rm -rf $T; }
case1 steady 0 "no decline over 10 %" 8 299.0
case1 decline-flagged 0 "FLAG for owner review: decline over 10 %: prefill" 8 250.0
case1 five-cycles 1 "INSUFFICIENT" 5 300.0
case1 missing-speed 1 "INVALID (cycle 7: no speed result)" 8 300.0 nospeed=7
case1 missing-temps 1 "INVALID (cycle 2: no temperature samples)" 8 300.0 notemp=2
T=$(mktemp -d); out=$(python3 $S $T $T 2>&1); rc=$?; [ $rc = 1 ] && [[ "$out" == *"INVALID (cycles.tsv unreadable"* ]] && echo "ok   no-cycles-file" || { echo "FAIL no-cycles-file: $out"; fails=$((fails+1)); }; rm -rf $T
echo "failures: $fails"; exit $fails
