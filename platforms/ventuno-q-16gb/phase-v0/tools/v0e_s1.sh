#!/bin/bash
# v0e_s1.sh — V0e session 1 workload (D112), run by run_v0e.sh with OUT, URL, SPID, LABEL set; steps 1-3 of the RUNBOOK on
# one server at window $WIN (pi model $PIM). Every item runs (more evidence), unless the server is gone; the item results
# go to $OUT/items.txt. Exit 0 only if every item passed.
#   1a probe_toolcalls probe --stream (10/10)       1b probe_toolcalls agentic --stream (3/3)      1c pi_smoke.py
#   2  v0e_window.py window (agreement, near-limit prompt, tool continuation)
#   3  v0e_window.py cache (cached multi-turn reuse vs fresh prefix)
#   2/3 v0e_compact.sh (real-pi compaction at the window)
set -uo pipefail
WIN=${WIN:-32768}; PIM=${PIM:-local32k}; T=~/v0/measure/suite/tools; EV=$(dirname "$OUT")/probe.txt
fails=0
item() { local name=$1; shift
  kill -0 "$SPID" 2>/dev/null || { echo "$(date -Is) $name: NOT RUN (server gone)" | tee -a "$OUT/items.txt"; exit 5; }
  local t0=$(date +%s); "$@" > "$OUT/$name.txt" 2>&1; local rc=$?
  echo "$(date -Is) $name: rc=$rc $(( $(date +%s)-t0 ))s | $(grep -h '^RESULT' "$OUT/$name.txt" | tail -1)" | tee -a "$OUT/items.txt"
  [ $rc = 0 ] || fails=$((fails+1)); }
item 1a-stream-probe python3 $T/probe_toolcalls.py probe "$LABEL" "$EV" --url "$URL" --stream
item 1b-stream-agentic python3 $T/probe_toolcalls.py agentic "$LABEL" "$EV" --url "$URL" --stream
item 1c-pi-smoke env PI_PROVIDER=bench PI_MODEL=$PIM python3 $T/pi_smoke.py "$LABEL" "$EV"
item 2-window python3 ~/v0/v0e_window.py window "$OUT" "$OUT/server.log" $WIN $PIM
item 3-cache python3 ~/v0/v0e_window.py cache "$OUT" "$OUT/server.log" $WIN $PIM
item 23-compaction bash ~/v0/v0e_compact.sh "$LABEL" $PIM "$EV"
echo "$(date -Is) items failed: $fails" | tee -a "$OUT/items.txt"; exit $fails
