#!/bin/bash
# offline tests for r2_placement.py. Fixtures (k5-r2/fixtures/), both R1 dry runs of the admitted configuration at
# af0579c78 with RPC devices standing in for the sessions (renamed HTP0:0..3):
#   s4-rp-ub512-production.log.gz   through the production logger (common_init, -lv 5: prefixes inside lines, as
#                                   llama-server writes them), from a clean (uninstrumented) tree;
#   s4-rp-ub512-rawcallback.log.gz  R1's raw log callback (no prefixes; the instrumentation's TYPES fields removed).
# Each case mutates one thing in the production log.
D=$(cd "$(dirname "$0")" && pwd); ND=$(cd "$D/.." && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; fails=0; n=0
TAB="$ND/r1-host/k3/table-M2.tsv"
zcat "$ND/k5-r2/fixtures/s4-rp-ub512-production.log.gz" > "$W/ok.log"; zcat "$ND/k5-r2/fixtures/s4-rp-ub512-rawcallback.log.gz" > "$W/raw.log"
expect() { local name=$1 want=$2 log=$3 var=${4:-NPU-R\'}; n=$((n + 1)); out=$(python3 -I "$D/r2_placement.py" "$log" --tensors "$TAB" --split 11,10,10,10 --variant "$var" 2>&1); rc=$?
  [ "$rc" = "$want" ] && echo "ok   $name (rc $rc: $(echo "$out" | grep -m1 '^DIFF' | cut -c1-80)$(echo "$out" | tail -1))" || { echo "FAIL $name (rc $rc, wanted $want): $(echo "$out" | tail -3 | tr '\n' ' ')"; fails=$((fails + 1)); }; }
expect "the production log of the admitted configuration: PLACED" 0 "$W/ok.log"
expect "the raw-callback log of the same run: PLACED" 0 "$W/raw.log"
sed 's/layer  15 assigned to device HTP0:1/layer  15 assigned to device HTP0:0/' "$W/ok.log" > "$W/a.log"; expect "a layer on another session: MISPLACED" 1 "$W/a.log"
grep -v 'layer  40 assigned' "$W/ok.log" > "$W/b.log"; expect "the output layer's loader line missing: MISPLACED" 1 "$W/b.log"
awk '/^## SPLIT #5: CPU/ && !d { sub("CPU", "HTP0:3"); d = 1 } { print }' "$W/ok.log" > "$W/c.log"; expect "the output projection's split not on the CPU: MISPLACED" 1 "$W/c.log"
grep -v '(\s*MUL_MAT_ID)\|(\s*MUL_MAT)' "$W/ok.log" > "$W/d.log"; expect "every matmul record removed (review of fdb7292): MISPLACED" 1 "$W/d.log"
awk '/blk\.12\.ffn_up_exps/ && /MUL_MAT_ID/ { next } { print }' "$W/ok.log" > "$W/e.log"; expect "one block's expert matmuls removed: MISPLACED" 1 "$W/e.log"
awk '/blk\.3\.shortconv\.in_p/ && /MUL_MAT/ { next } { print }' "$W/ok.log" > "$W/f.log"; expect "one block's short-convolution matmul removed: MISPLACED" 1 "$W/f.log"
python3 -I - "$W/ok.log" "$W/g.log" <<'PY'
import sys
# move block 5's ffn_gate_exps matmul from session 0's split into session 2's (the first graph)
L = open(sys.argv[1]).read().split("\n"); i = next(k for k, l in enumerate(L) if "blk.5.ffn_gate_exps" in l and "MUL_MAT_ID" in l)
line = L.pop(i); j = next(k for k, l in enumerate(L) if l.startswith("## SPLIT #3: HTP0:2")); L.insert(j + 1, line)
open(sys.argv[2], "w").write("\n".join(L))
PY
expect "a block-5 expert matmul under session 2: MISPLACED" 1 "$W/g.log"
expect "the NPU-R' log checked as NPU-R: MISPLACED" 1 "$W/ok.log" NPU-R
grep -v ' D ' "$W/ok.log" | grep -v '^## SPLIT\|^node #' > "$W/h.log"; expect "a -lv 4 log (no debug lines): invalid" 3 "$W/h.log"
grep -v 'assigned to device' "$W/ok.log" > "$W/i.log"; expect "no loader lines: invalid" 3 "$W/i.log"
awk '/ D node #/ && !d { print "0.00.000.001 D node # 1 (MUL_MAT): broken"; d = 1; next } { print }' "$W/ok.log" > "$W/j.log"; expect "a node line that does not parse: invalid" 3 "$W/j.log"
expect "no log: invalid" 3 "$W/none.log"
echo "failures: $fails of $n"; exit $fails
