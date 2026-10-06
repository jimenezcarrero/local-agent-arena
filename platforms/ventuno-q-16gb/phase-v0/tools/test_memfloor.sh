#!/bin/bash
# synthetic tests for memfloor.py --admit (Codex review 14:08Z finding 1): exit 0 only with samples and L_min >= cap + 0.33 GiB
T=$(mktemp -d); fails=0; mkdir -p $T/mon $T/run
t0=1791300000
printf '%s server pid 1\n%s END rc=0\n' "$(date -Is -d @$t0)" "$(date -Is -d @$((t0+300)))" > $T/run/run.txt
printf '0.00.100.000 I srv  update:  - cache state: 0 prompts, 0.000 MiB (limits)\n' > $T/run/server.log
chk() { MONITOR_DIR=$T/mon python3 ~/v0/memfloor.py --admit $2 $T/run > /dev/null 2>&1; local rc=$?
  if { [ "$3" = admit ] && [ $rc = 0 ]; } || { [ "$3" = reject ] && [ $rc != 0 ]; }; then echo "ok   $1 -> rc=$rc"; else echo "FAIL $1 -> rc=$rc (want $3)"; fails=$((fails+1)); fi; }
# 1. empty monitoring dir: no samples -> reject
chk empty-monitor 1000 reject
# samples: L = MemAvailable (cache 0); cap 1000 MiB -> need 1000*1024 + 0.33*2^20 = 1370030.08 kB
need=$(python3 -c "print(1000*1024 + 0.33*2**20)")
for e in $(seq $((t0+60)) 10 $((t0+290))); do echo "{\"epoch\": $e, \"MemAvailable_kB\": 2000000}" ; done > $T/mon/health-20990101.jsonl
chk above 1000 admit
# 2. one sample just below the threshold (boundary) -> reject
echo "{\"epoch\": $((t0+295)), \"MemAvailable_kB\": $(python3 -c "import math; print(math.floor($need) - 1)")}" >> $T/mon/health-20990101.jsonl
chk boundary-below 1000 reject
# 3. exactly at the threshold, rounded up -> admit
sed -i '$d' $T/mon/health-20990101.jsonl; echo "{\"epoch\": $((t0+295)), \"MemAvailable_kB\": $(python3 -c "import math; print(math.ceil($need))")}" >> $T/mon/health-20990101.jsonl
chk boundary-at 1000 admit
# 4. samples exist but none in the run window -> reject
for e in 1 2 3; do echo "{\"epoch\": $e, \"MemAvailable_kB\": 9000000}"; done > $T/mon/health-20990101.jsonl
chk outside-window 1000 reject
# 5. missing server log -> reject
rm $T/run/server.log; chk no-server-log 1000 reject
rm -rf $T; echo "failures: $fails"; exit $fails
