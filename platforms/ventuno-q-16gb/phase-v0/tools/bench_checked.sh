#!/bin/bash
# bench_checked.sh <label> <phase> <expected rows> -- <llama-bench command...> (Codex review of #45 20:32Z, finding 2)
#   llama-bench under the same evidence rules as run_route.sh: frozen checkout checked, run window registered, command,
#   binary and model identities recorded, timeout, exit status, output validated (exactly <expected rows> result rows,
#   each with a numeric t/s), successful kernel read after END, health verdict and kernel audit. stderr goes to
#   server.log so classify() (v0d_lib.sh) sees NPU aborts. Output: ~/bench-runs/v0/<phase>/<label>/.
#   Env: BENCH_TIMEOUT (s, default 2400); V0, MEASURE, MON, OUTROOT override paths (tests: tools/test_bench_checked.sh). RESULT PASS only if every check passes.
set -uo pipefail
label=$1 phase=$2 rows=$3; shift 3; [ "$1" = -- ] && shift; cmd=("$@")
V0=${V0:-$HOME/v0}; MEASURE=${MEASURE:-$V0/measure}; MON=${MON:-$HOME/bench-runs/monitor}; OUT=${OUTROOT:-$HOME/bench-runs/v0}/$phase/$label
mkdir -p "$OUT"; cd "$OUT" || exit 1
log() { echo "$(date -Is) $*" | tee -a "$OUT/run.txt"; }
[ "$(git -C $MEASURE rev-parse HEAD)" = 7badb21a23384379e208d56defab9b0781c5e457 ] || { log "ABORT measure checkout moved"; exit 3; }
for pn in ${EXCL_PROCS:-llama-server llama-bench}; do pgrep -x $pn > /dev/null && { log "ABORT another llama process is running ($pn)"; exit 3; }; done
bin=$(for a in "${cmd[@]}"; do case $a in */llama-bench) echo $a;; esac; done | head -1)
model=$(for i in "${!cmd[@]}"; do [ "${cmd[$i]}" = -m ] && echo "${cmd[$((i+1))]}"; done | head -1)
log "START label=$label phase=$phase measure=$(git -C $MEASURE rev-parse --short HEAD) boot=$(cat /proc/sys/kernel/random/boot_id)"
log "BENCH ${cmd[*]}"
log "IDENTITY bin_sha256=$(sha256sum "$bin" 2>/dev/null | cut -c1-64) lib_sha256=$(cat "$(dirname "$bin")"/../lib/libggml-hexagon.so 2>/dev/null | sha256sum | cut -c1-64) model=$(basename "$model") model_bytes=$(stat -c %s "$model" 2>/dev/null)"
free -m > "$OUT/free-start.txt"; start=$(date +%s)
echo "{\"label\":\"$phase/$label\",\"start_epoch\":$start,\"end_epoch\":null}" >> $MON/run-windows.jsonl
timeout -k 30 ${BENCH_TIMEOUT:-2400} "${cmd[@]}" -o md > "$OUT/bench.md" 2> "$OUT/server.log"; rc=$?
for p in $(pgrep -x llama-bench); do kill -KILL $p; done
end=$(date +%s)
python3 - "$MON/run-windows.jsonl" "$phase/$label" "$start" "$end" <<'PY'
import json, os, sys
p, label, start, end = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
rows = [json.loads(l) for l in open(p) if l.strip()]
for r in rows:
    if r["label"] == label and r["start_epoch"] == start: r["end_epoch"] = end
open(p + ".tmp", "w").write("".join(json.dumps(r) + "\n" for r in rows)); os.replace(p + ".tmp", p)
PY
free -m > "$OUT/free-end.txt"; log "END rc=$rc duration=$((end-start))s"
# output: exactly the expected number of result rows, each with a numeric "t/s" cell (mean ± sd)
got=$(grep -cE '^\| .*\| +[0-9.]+ ± [0-9.]+ \|$' "$OUT/bench.md"); all=$(grep -E '^\| ' "$OUT/bench.md" | grep -vcE '^\| (model|-)')
out=ok; { [ "$got" = "$rows" ] && [ "$all" = "$rows" ]; } || out="malformed(rows=$all numeric=$got want=$rows)"
kwait=TIMEOUT
for i in $(seq 1 12); do
  if python3 -c "import json,sys
rows=[]
for l in open(sys.argv[1], errors='replace'):
    try: r=json.loads(l)
    except ValueError: continue
    if r.get('kern_read')=='ok' and r.get('kern_parse')!='FAILED' and isinstance(r.get('kern_alert_lines'),int): rows.append(r)
sys.exit(0 if rows and rows[-1]['epoch']>int(sys.argv[2]) else 1)" $MON/health-$(date -u +%Y%m%d).jsonl $end; then kwait=ok; break; fi
  sleep 10
done
MONITOR_DIR=$MON python3 $V0/monitor/health_check.py $(( (end-start)/60 + 3 )) > "$OUT/health.txt" 2>&1; hc=$?
hverdict=$(python3 $V0/health_verdict.py "$OUT/health.txt" "$hc"); rc_health=$?; echo "$hverdict" > "$OUT/health-verdict.txt"
MONITOR_DIR=$MON python3 $V0/kernel_audit.py "$OUT" > "$OUT/kernel-audit.txt" 2>&1; rc_k=$?
fails=""
[ "$rc" = 0 ] || fails="$fails bench=$rc"
[ "$out" = ok ] || fails="$fails output=$out"
[ "$rc_health" = 0 ] || fails="$fails health=($hverdict)"
[ "$kwait" = ok ] || fails="$fails kernel_read_after_end=$kwait"
[ "$rc_k" = 0 ] && [ "$(head -1 "$OUT/kernel-audit.txt" | cut -d' ' -f1)" = pass ] || fails="$fails kernel_audit=($(head -1 "$OUT/kernel-audit.txt" | cut -c1-60))"
if [ -z "$fails" ]; then log "RESULT PASS (bench, health: $hverdict, kernel evidence, kernel audit)"; exit 0
else log "RESULT FAIL:$fails"; exit 1; fi
