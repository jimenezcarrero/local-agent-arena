#!/bin/bash
# run_v0c.sh <label> <route-kind: llama|geniex> <watchdog-s or 0> -- <server command...>
#   One V0c route x file run at the frozen measurement commit:
#   1. speed_probe.py --depths 512,8192,16384,32768 --nctx 40960
#   2. VmHWM of every server process (the runbook's end-of-32K point)
#   3. probe_toolcalls.py probe   (10 one-shot)
#   4. probe_toolcalls.py agentic (3 loops)
#   Run window registered; health check over the window. GenieX: --url/--model, tool probes with --no-props.
#   Watchdog (GenieX hybrid): if the server log and server CPU both stall for <watchdog-s>, the server is
#   killed and the stall recorded (stall-diagnosis.txt); the client probes then fail and are recorded.
set -uo pipefail
label=$1 kind=$2 wd=$3; shift 4
server=("$@")
P=v0c; MEASURE=~/v0/measure; MON=~/bench-runs/monitor
OUT=~/bench-runs/v0/$P/$label; SPEED=~/bench-runs/v0/$P/speed.txt; TOOLS=~/bench-runs/v0/$P/probe.txt
mkdir -p "$OUT"; cd ~/bench-runs || exit 1
log() { echo "$(date -Is) $*" | tee -a "$OUT/run.txt"; }
if [ "$kind" = geniex ]; then URL=http://127.0.0.1:18181; HEALTH=$URL/v1/models; MODEL=$GENIEX_MODEL
  SP=(--url $URL --model "$MODEL"); TP=(--url $URL --model "$MODEL" --no-props)
else URL=http://127.0.0.1:8080; HEALTH=$URL/health; SP=(--url $URL); TP=(--url $URL); fi

[ "$(git -C $MEASURE rev-parse HEAD)" = 7badb21a23384379e208d56defab9b0781c5e457 ] || { log "ABORT measure checkout moved"; exit 3; }
[ -z "$(git -C $MEASURE status --porcelain)" ] || { log "ABORT measure checkout dirty"; exit 3; }
python3 ~/v0/corpus_check.py "$OUT/corpus-check.txt" > /dev/null || { log "ABORT corpus mismatch (see corpus-check.txt)"; exit 3; }
if curl -s -m 2 -o /dev/null "$HEALTH"; then log "ABORT something already answers on $HEALTH"; exit 3; fi
log "START label=$label kind=$kind measure=7badb21 boot=$(cat /proc/sys/kernel/random/boot_id) watchdog=${wd}s"
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

wdpid=
if [ $ok = 1 ] && [ "$wd" -gt 0 ]; then
  ( lastsz=-1; lastcpu=0; stall=0
    while kill -0 $spid 2>/dev/null; do
      sz=$(stat -c%s "$OUT/server.log" 2>/dev/null || echo 0)
      cpu=0; for p in $(pgrep -g $spid); do c=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null || echo 0); cpu=$((cpu+c)); done
      if [ "$sz" = "$lastsz" ] && [ $((cpu-lastcpu)) -lt 50 ]; then stall=$((stall+10)); else stall=0; fi
      lastsz=$sz; lastcpu=$cpu
      if [ $stall -ge "$wd" ]; then
        { echo "# watchdog stop $(date -Is): ${wd}s without server-log growth and <0.5 core-s per 10 s"
          echo "# last log line: $(sed 's/\x1b\[[0-9;]*m//g' "$OUT/server.log" | tail -1 | cut -c1-200)"
          for p in $(pgrep -g $spid); do for t in /proc/$p/task/*; do echo "$(awk '{print $3}' $t/stat) $(cat $t/wchan 2>/dev/null) $(cat $t/comm)"; done; done | sort | uniq -c | sort -rn
        } > "$OUT/stall-diagnosis.txt"
        echo "$(date -Is) WATCHDOG killed server after ${wd}s stall" >> "$OUT/run.txt"
        kill -KILL -- -$spid 2>/dev/null; break
      fi
      sleep 10
    done ) &
  wdpid=$!
fi

rc_speed=4 rc_probe=4 rc_agentic=4
if [ $ok = 1 ]; then
  log "ready after ${i}s"
  python3 $MEASURE/suite/tools/speed_probe.py "$label" "$SPEED" --depths 512,8192,16384,32768 --nctx 40960 "${SP[@]}" > "$OUT/speed.txt" 2>&1; rc_speed=$?
  log "speed_probe rc=$rc_speed"
  for p in $(pgrep -g $spid 2>/dev/null); do printf '%s %s %s\n' "$p" "$(grep -E 'VmHWM|VmRSS' /proc/$p/status 2>/dev/null | tr -s ' \t' ' ' | paste -sd' ')" "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-80)"; done > "$OUT/vmhwm.txt"
  log "VmHWM after 32K probe: $(sort -t: -k2 -n "$OUT/vmhwm.txt" | tail -1 | cut -c1-90)"
  if kill -0 $spid 2>/dev/null; then
    python3 $MEASURE/suite/tools/probe_toolcalls.py probe "$label" "$TOOLS" "${TP[@]}" > "$OUT/toolprobe.txt" 2>&1; rc_probe=$?
    log "probe_toolcalls probe rc=$rc_probe"
    python3 $MEASURE/suite/tools/probe_toolcalls.py agentic "$label" "$TOOLS" "${TP[@]}" > "$OUT/toolagentic.txt" 2>&1; rc_agentic=$?
    log "probe_toolcalls agentic rc=$rc_agentic"
  else log "server gone before tool probes (see stall-diagnosis.txt / server.log)"; fi
fi
[ -n "$wdpid" ] && kill $wdpid 2>/dev/null
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
log "END speed=$rc_speed probe=$rc_probe agentic=$rc_agentic duration=$((end-start))s"
python3 ~/v0/monitor/health_check.py $(( (end-start)/60 + 3 )) > "$OUT/health.txt" 2>&1
