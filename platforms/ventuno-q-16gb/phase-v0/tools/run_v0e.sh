#!/bin/bash
# run_v0e.sh <label> <workload> -- <server command...>   (V0e, D112; built from run_v0c.sh)
#   One V0e server session at the frozen measurement commit: start the server, wait for /health, run <workload> with
#   OUT (this run dir), URL, SPID and LABEL exported, stop the server, then the same evidence chain as run_v0c.sh: run
#   window registered and closed, a successful kernel-journal read after the end, health check + fail-closed verdict,
#   kernel window. The NPU stall watchdog (npu_stall_watchdog.sh) runs outside and is read by classify().
#   RESULT PASS only if the workload exited 0 and health and kernel evidence passed. A server that never became ready
#   is "RESULT FAIL: load=4" (classify() -> EVIDENCE -> stop: V0e does not retry loads).
set -uo pipefail
label=$1 workload=$2; shift 3
server=("$@")
P=${PHASE:?PHASE}; MEASURE=~/v0/measure; MON=~/bench-runs/monitor
OUT=~/bench-runs/v0/$P/$label; URL=http://127.0.0.1:8080; HEALTH=$URL/health
mkdir -p "$OUT"; cd ~/bench-runs || exit 1
log() { echo "$(date -Is) $*" | tee -a "$OUT/run.txt"; }
[ "$(git -C $MEASURE rev-parse HEAD)" = 7badb21a23384379e208d56defab9b0781c5e457 ] || { log "ABORT measure checkout moved"; exit 3; }
[ -z "$(git -C $MEASURE status --porcelain)" ] || { log "ABORT measure checkout dirty"; exit 3; }
python3 ~/v0/corpus_check.py "$OUT/corpus-check.txt" > /dev/null || { log "ABORT corpus mismatch (see corpus-check.txt)"; exit 3; }
if curl -s -m 2 -o /dev/null "$HEALTH"; then log "ABORT something already answers on $HEALTH"; exit 3; fi
log "START label=$label workload=$(basename "$workload") measure=7badb21 boot=$(cat /proc/sys/kernel/random/boot_id)"
log "SERVER ${server[*]}"
free -m > "$OUT/free-start.txt"
start=$(date +%s)
echo "{\"label\":\"$P/$label\",\"start_epoch\":$start,\"end_epoch\":null}" >> $MON/run-windows.jsonl
setsid "${server[@]}" > "$OUT/server.log" 2>&1 < /dev/null &
spid=$!; log "server pid $spid"
ok=0; for i in $(seq 1 900); do
  kill -0 $spid 2>/dev/null || { log "SERVER EXITED before ready"; break; }
  [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$HEALTH")" = 200 ] && { ok=1; break; }
  sleep 1; done
rc_load=4 rc_work=4
if [ $ok = 1 ]; then rc_load=0
  log "ready after ${i}s"
  OUT=$OUT URL=$URL SPID=$spid LABEL=$label bash "$workload" > "$OUT/workload.txt" 2>&1; rc_work=$?
  log "workload rc=$rc_work"
  for p in $(pgrep -g $spid 2>/dev/null); do printf '%s %s %s\n' "$p" "$(grep -E 'VmHWM|VmRSS' /proc/$p/status 2>/dev/null | tr -s ' \t' ' ' | paste -sd' ')" "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-80)"; done > "$OUT/vmhwm.txt"
  kill -0 $spid 2>/dev/null && log "server still up at the end of the workload" || { log "server GONE before the end of the workload"; rc_work=5; }
fi
kill -TERM -- -$spid 2>/dev/null; for i in $(seq 1 30); do kill -0 $spid 2>/dev/null || break; sleep 1; done
kill -0 $spid 2>/dev/null && { log "server ignored SIGTERM for 30 s, SIGKILL"; kill -KILL -- -$spid 2>/dev/null; }
end=$(date +%s)
python3 - "$MON/run-windows.jsonl" "$P/$label" "$start" "$end" <<'PY'
import json, os, sys
p, label, start, end = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
rows = [json.loads(l) for l in open(p) if l.strip()]
for r in rows:
    if r["label"] == label and r["start_epoch"] == start: r["end_epoch"] = end
open(p + ".tmp", "w").write("".join(json.dumps(r) + "\n" for r in rows)); os.replace(p + ".tmp", p)
PY
free -m > "$OUT/free-end.txt"
log "END load=$rc_load workload=$rc_work duration=$((end-start))s"
kwait=TIMEOUT
for i in $(seq 1 12); do
  if python3 -c "import json,sys
rows=[]
for l in open(sys.argv[1], errors='replace'):
    try: r=json.loads(l)
    except ValueError: continue
    if r.get('kern_read')=='ok' and r.get('kern_parse')!='FAILED' and isinstance(r.get('kern_alert_lines'),int): rows.append(r)
sys.exit(0 if rows and rows[-1]['epoch']>int(sys.argv[2]) else 1)" ~/bench-runs/monitor/health-$(date -u +%Y%m%d).jsonl $end; then kwait=ok; break; fi
  sleep 10
done
python3 ~/v0/monitor/health_check.py $(( (end-start)/60 + 3 )) > "$OUT/health.txt" 2>&1; hc=$?
hverdict=$(python3 ~/v0/health_verdict.py "$OUT/health.txt" "$hc"); rc_health=$?
echo "$hverdict" > "$OUT/health-verdict.txt"
python3 - "$start" > "$OUT/kernel-window.txt" 2>&1 <<'PY'
import glob, json, os, sys, time
t0 = int(sys.argv[1]) - 60
for f in sorted(glob.glob(os.path.expanduser("~/bench-runs/monitor/kernel-*.jsonl")))[-2:]:
    for l in open(f):
        k = json.loads(l); t = int(k.get("__REALTIME_TIMESTAMP", 0)) / 1e6
        if t >= t0:
            print(time.strftime("%FT%T", time.localtime(t)), str(k.get("MESSAGE", ""))[:240])
PY
rc_kwin=$?
fails=""
[ "$rc_load" = 0 ] || fails="$fails load=$rc_load"
[ "$rc_load" = 0 ] && [ "$rc_work" != 0 ] && fails="$fails workload=$rc_work"
[ "$rc_health" = 0 ] || fails="$fails health=($hverdict)"
[ "$kwait" = ok ] || fails="$fails kernel_read_after_end=$kwait"
[ "$rc_kwin" = 0 ] || fails="$fails kernel_window=$rc_kwin"
if [ -z "$fails" ]; then log "RESULT PASS (workload, health: $hverdict, kernel evidence)"; exit 0
else log "RESULT FAIL:$fails"; exit 1; fi
