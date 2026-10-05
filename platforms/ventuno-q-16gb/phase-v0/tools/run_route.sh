#!/bin/bash
# run_route.sh <label> <phase> <probe args...> -- <server command...>
#   One measured route run: frozen-corpus check, run window registered, server started with the exact
#   command, health wait, speed_probe.py from the frozen checkout (~/v0/measure), VmHWM read before stop,
#   server stopped, window closed. Everything lands in ~/bench-runs/v0/<phase>/<label>/ plus the phase's
#   shared evidence file ~/bench-runs/v0/<phase>/speed.txt.
#   Env: URL (default http://127.0.0.1:8080), HEALTH (default $URL/health), READY_TIMEOUT (s, default 600).
set -uo pipefail
label=$1 phase=$2; shift 2
probe=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do probe+=("$1"); shift; done; shift
server=("$@")
URL=${URL:-http://127.0.0.1:8080}; HEALTH=${HEALTH:-$URL/health}; READY_TIMEOUT=${READY_TIMEOUT:-600}
MEASURE=~/v0/measure; MON=~/bench-runs/monitor
OUT=~/bench-runs/v0/$phase/$label; EVID=~/bench-runs/v0/$phase/speed.txt
mkdir -p "$OUT"; cd ~/bench-runs || exit 1
log() { echo "$(date -Is) $*" | tee -a "$OUT/run.txt"; }

# 1. frozen corpus
[ "$(git -C $MEASURE rev-parse HEAD)" = 7badb21a23384379e208d56defab9b0781c5e457 ] || { log "ABORT measure checkout moved: $(git -C $MEASURE rev-parse HEAD)"; exit 3; }
[ -z "$(git -C $MEASURE status --porcelain)" ] || { log "ABORT measure checkout dirty"; exit 3; }
python3 ~/v0/corpus_check.py "$OUT/corpus-check.txt" > /dev/null || { log "ABORT corpus mismatch (see corpus-check.txt)"; exit 3; }
# 2. one server at a time
if curl -s -m 2 -o /dev/null "$HEALTH"; then log "ABORT something already answers on $HEALTH"; exit 3; fi
log "START label=$label phase=$phase measure=$(git -C $MEASURE rev-parse --short HEAD) boot=$(cat /proc/sys/kernel/random/boot_id)"
log "SERVER ${server[*]}"
log "PROBE speed_probe.py $label $EVID ${probe[*]}"
free -m > "$OUT/free-start.txt"
start=$(date +%s)
echo "{\"label\":\"$phase/$label\",\"start_epoch\":$start,\"end_epoch\":null}" >> $MON/run-windows.jsonl
# 3. server
setsid "${server[@]}" > "$OUT/server.log" 2>&1 < /dev/null &
spid=$!
log "server pid $spid"
ok=0
for i in $(seq 1 "$READY_TIMEOUT"); do
  if ! kill -0 $spid 2>/dev/null; then log "SERVER EXITED before ready (see server.log)"; break; fi
  if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$HEALTH")" = 200 ]; then ok=1; break; fi
  sleep 1
done
rc=4
if [ $ok = 1 ]; then
  log "ready after ${i}s"
  # pid of the process that actually holds the model (the launcher may be a wrapper script)
  mpid=$(pgrep -P $spid -n 2>/dev/null || true); mpid=${mpid:-$spid}
  for p in $(pgrep -g $spid 2>/dev/null); do echo "$p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-150)"; done > "$OUT/procs.txt"
  python3 $MEASURE/suite/tools/speed_probe.py "$label" "$EVID" "${probe[@]}" > "$OUT/probe.txt" 2>&1; rc=$?
  log "speed_probe rc=$rc"
  for p in $(pgrep -g $spid 2>/dev/null); do printf '%s %s %s\n' "$p" "$(grep -E 'VmHWM|VmRSS' /proc/$p/status 2>/dev/null | tr -s ' \t' ' ' | paste -sd' ')" "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-80)"; done > "$OUT/vmhwm.txt"
  log "VmHWM $(sort -t: -k2 -n "$OUT/vmhwm.txt" | tail -1)"
fi
# 4. stop the whole server process group
kill -TERM -- -$spid 2>/dev/null; for i in $(seq 1 30); do kill -0 $spid 2>/dev/null || break; sleep 1; done
kill -KILL -- -$spid 2>/dev/null
end=$(date +%s)
python3 - "$MON/run-windows.jsonl" "$phase/$label" "$start" "$end" <<'PY'
import json, sys
p, label, start, end = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
rows = [json.loads(l) for l in open(p) if l.strip()]
for r in rows:
    if r["label"] == label and r["start_epoch"] == start: r["end_epoch"] = end
open(p + ".tmp", "w").write("".join(json.dumps(r) + "\n" for r in rows))
import os; os.replace(p + ".tmp", p)
PY
free -m > "$OUT/free-end.txt"
log "END rc=$rc duration=$((end-start))s"
python3 ~/v0/monitor/health_check.py $(( (end-start)/60 + 3 )) > "$OUT/health.txt" 2>&1; rc_health=0
# health counts as failed on real alerts only; memory-PSI spikes (every large model load) stay visible as ALERT lines
grep -E '^ALERT' "$OUT/health.txt" | grep -vq 'memory PSI' && rc_health=1
[ -s "$OUT/health.txt" ] || rc_health=5
# Aggregate: speed probe and health check must both pass (health_check exits 1 on any ALERT or evidence gap)
if [ "$rc" = 0 ] && [ "$rc_health" = 0 ]; then log "RESULT PASS (speed, health)"; exit 0
else log "RESULT FAIL: speed=$rc health=$rc_health"; exit 1; fi
