#!/bin/bash
# offline tests for r2_logged_buffers.py on synthetic -lv 4 logs (af0579c78 formats) against the committed ledger
# (config s4-rp-ub512: model 2110.47/2275.63/2274.50/2047.85, KV+RS 96.12/64.12/96.11/64.11, compute 101.01/60.38/60.38/
# 64.01 MiB, CPU bound 286.02 MiB)
D=$(cd "$(dirname "$0")" && pwd); ND=$(cd "$D/.." && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; fails=0; n=0
ln() { printf '%s: %12s %s buffer size = %8.2f MiB\n' "$1" "$2" "$3" "$4"; }
good() {  # model as 1 GiB pieces for session 0, KV and RS split, compute at the ledger + $1 on session 2, host compute $2
  ln load_tensors HTP0:0 model 1024.00; ln load_tensors HTP0:0 model 1024.00; ln load_tensors HTP0:0 model 62.47
  ln load_tensors HTP0:1 model 2275.63; ln load_tensors HTP0:2 model 2274.50; ln load_tensors HTP0:3 model 2047.85
  ln load_tensors CPU model 410.16
  for s in 0:96.00:0.12 1:64.00:0.12 2:96.00:0.11 3:64.00:0.11; do IFS=: read i kv rs <<< "$s"
    ln llama_kv_cache HTP0:$i KV $kv; ln llama_memory_recurrent HTP0:$i RS $rs; done
  ln sched_reserve HTP0:0 compute 101.01; ln sched_reserve HTP0:1 compute 60.38
  ln sched_reserve HTP0:2 compute "$(python3 -c "print(60.38 + $1)")"; ln sched_reserve HTP0:3 compute 64.01
  ln sched_reserve HTP0:0-HOST compute "$2"; }
expect() { local name=$1 want=$2 log=$3 cfg=${4:-s4-rp-ub512}; n=$((n + 1)); out=$(python3 -I "$D/r2_logged_buffers.py" "$ND" "$log" "$cfg" 2>&1); rc=$?
  [ "$rc" = "$want" ] && echo "ok   $name (rc $rc: $(echo "$out" | tail -1))" || { echo "FAIL $name (rc $rc, wanted $want): $(echo "$out" | tail -3 | tr '\n' ' ')"; fails=$((fails + 1)); }; }
good 0 258.00 > "$W/a.log"; expect "the ledger's own figures, model in three 1 GiB pieces: within" 0 "$W/a.log"
good 0.9 258.00 > "$W/b.log"; expect "compute 0.9 MiB above the dry run (the alignment allowance): within" 0 "$W/b.log"
good 1.2 258.00 > "$W/c.log"; expect "compute 1.2 MiB above the dry run: over" 1 "$W/c.log"
good 0 290.00 > "$W/d.log"; expect "host compute above the CPU bound: over" 1 "$W/d.log"
{ good 0 258.00; ln load_tensors HTP0:1 model 10.00; } > "$W/e.log"; expect "an extra model buffer on session 1: over" 1 "$W/e.log"
good 0 258.00 | grep -v 'HTP0:3 compute' > "$W/f.log"; expect "a session without a compute line: invalid" 3 "$W/f.log"
{ good 0 258.00; ln load_tensors HTP0:4 model 1.00; } > "$W/g.log"; expect "a buffer outside the configuration's sessions: invalid" 3 "$W/g.log"
expect "an unknown ledger config: invalid" 3 "$W/a.log" s9-nothing
expect "no log: invalid" 3 "$W/none.log"
good 0 258.00 | sed 's/HTP0:0-HOST compute/         CPU compute/' > "$W/h.log"; expect "the CPU compute buffer named CPU (as a real NPU log names it): within" 0 "$W/h.log"
good 0 290.00 | sed 's/HTP0:0-HOST compute/         CPU compute/' > "$W/i.log"; expect "a CPU-named compute buffer above the bound: over" 1 "$W/i.log"
good 0 258.00 | grep -v 'HOST compute' > "$W/j.log"; expect "no CPU compute line at all: invalid" 3 "$W/j.log"
echo "failures: $fails of $n"; exit $fails
