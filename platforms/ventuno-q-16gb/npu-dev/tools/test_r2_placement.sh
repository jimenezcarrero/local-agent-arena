#!/bin/bash
# offline tests for r2_placement.py. The fixture k5-r2/fixtures/s4-rp-ub512-placement.log.gz is R1's dry run of the
# admitted configuration (af0579c78's own loader and scheduler output, RPC devices standing in for the sessions):
# loader lines and every graph's split and node lines, the RPC devices renamed to HTP0:0..3 and the R1 instrumentation's
# TYPES fields removed. Each case mutates one thing.
D=$(cd "$(dirname "$0")" && pwd); ND=$(cd "$D/.." && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; fails=0; n=0
zcat "$ND/k5-r2/fixtures/s4-rp-ub512-placement.log.gz" > "$W/ok.log"
expect() { local name=$1 want=$2 log=$3 var=${4:-NPU-R\'}; n=$((n + 1)); out=$(python3 -I "$D/r2_placement.py" "$log" --split 11,10,10,10 --variant "$var" 2>&1); rc=$?
  [ "$rc" = "$want" ] && echo "ok   $name (rc $rc: $(echo "$out" | grep -m1 '^DIFF' | cut -c1-90)$(echo "$out" | tail -1))" || { echo "FAIL $name (rc $rc, wanted $want): $(echo "$out" | tail -3 | tr '\n' ' ')"; fails=$((fails + 1)); }; }
expect "the dry run's own placement: PLACED" 0 "$W/ok.log"
sed 's/layer  15 assigned to device HTP0:1/layer  15 assigned to device HTP0:0/' "$W/ok.log" > "$W/a.log"; expect "a layer on another session: MISPLACED" 1 "$W/a.log"
grep -v 'layer  40 assigned' "$W/ok.log" > "$W/b.log"; expect "the output layer's loader line missing: MISPLACED" 1 "$W/b.log"
awk '/^## SPLIT #5: CPU/ && !d { sub("CPU", "HTP0:3"); d = 1 } { print }' "$W/ok.log" > "$W/c.log"; expect "the output projection's split not on the CPU: MISPLACED" 1 "$W/c.log"
awk '/^## SPLIT #3: HTP0:2/ { s = 1 } s && /MUL_MAT_ID/ && /-25 \(/ && !d { sub("-25 \\(", "-5 ("); d = 1 } { print }' "$W/ok.log" > "$W/d.log"; expect "a block-5 expert matmul under session 2: MISPLACED" 1 "$W/d.log"
expect "the NPU-R' log checked as NPU-R: MISPLACED" 1 "$W/ok.log" NPU-R
grep -v '^## SPLIT\|^node #' "$W/ok.log" > "$W/e.log"; expect "no scheduler graph: invalid" 3 "$W/e.log"
grep -v 'assigned to device' "$W/ok.log" > "$W/f.log"; expect "no loader lines: invalid" 3 "$W/f.log"
expect "no log: invalid" 3 "$W/none.log"
echo "failures: $fails of $n"; exit $fails
