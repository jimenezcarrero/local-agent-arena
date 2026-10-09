#!/bin/bash
# v0e_sustained.sh — V0e session 2 workload (D112, RUNBOOK V0e step 4), run by run_v0e.sh with OUT, URL, SPID, LABEL set.
# One server kept up for >= SUST_MIN minutes (default 95) of a repeating workload; each cycle:
#   - speed_probe.py at depth 8192 (fresh prefix: a new nonce and cache_prompt false), 128 tokens -> $OUT/speed.txt;
#   - one real-pi smoke session (pi_smoke.py, its own label per cycle) -> $OUT/smoke.txt.
# Temperatures, clocks, MemAvailable, swap, PSI and kernel lines come from the health sampler (10 s) over the run window.
# Each cycle's start/end epochs go to $OUT/cycles.tsv; at the end v0e_sustained_summary.py (D117) writes
# $OUT/sustained-summary.txt: first 3 vs last 3 cycles (throughput, NSP/CPU temperatures, a >10 % decline flagged).
# Exit 0 only if the server stayed up, the duration was reached, every speed probe gave a valid result and the summary
# is VALID (>= 6 cycles, each with a speed result and temperature samples). pi smoke results are counted and reported
# (the step-1 gate is the smoke's pass/fail; here it is the repeating load).
set -uo pipefail
SUST_MIN=${SUST_MIN:-95}; PIM=${PIM:-local32k}; T=~/v0/measure/suite/tools
t_end=$(( $(date +%s) + SUST_MIN*60 )); n=0 bad=0 sp=0 sf=0
while [ "$(date +%s)" -lt $t_end ]; do n=$((n+1)); c0=$(date +%s)
  kill -0 "$SPID" 2>/dev/null || { echo "$(date -Is) cycle $n: server GONE"; exit 5; }
  python3 $T/speed_probe.py "$LABEL-c$n" "$OUT/speed.txt" --depths 8192 --nctx 32768 --url "$URL" > "$OUT/speed-c$n.txt" 2>&1; rc=$?
  r=$(grep -E '^RESULT .*depth=8192 ' "$OUT/speed-c$n.txt" | grep -v ERROR | tail -1)
  { [ $rc = 0 ] && [ -n "$r" ]; } || bad=$((bad+1))
  env PI_PROVIDER=bench PI_MODEL=$PIM python3 $T/pi_smoke.py "$LABEL-c$n" "$OUT/smoke.txt" > "$OUT/smoke-c$n.txt" 2>&1 && sp=$((sp+1)) || sf=$((sf+1))
  echo "$n $c0 $(date +%s)" >> "$OUT/cycles.tsv"
  echo "$(date -Is) cycle $n: speed rc=$rc ${r:-NO RESULT} | smoke $(grep -h '^RESULT' "$OUT/smoke-c$n.txt" | tail -1)"
done
echo "$(date -Is) cycles=$n speed_invalid=$bad smoke_pass=$sp smoke_fail=$sf duration_target=${SUST_MIN}min"
kill -0 "$SPID" 2>/dev/null || exit 5
python3 ${SUMMARY:-$HOME/v0/v0e_sustained_summary.py} "$OUT" > "$OUT/sustained-summary.txt" 2>&1; rs=$?
tail -1 "$OUT/sustained-summary.txt"
[ $bad = 0 ] && [ $rs = 0 ]
