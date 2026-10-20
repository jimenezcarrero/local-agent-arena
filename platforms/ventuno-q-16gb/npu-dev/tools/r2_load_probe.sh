#!/bin/bash
# r2_load_probe.sh (NPU dev plan R2) — the payload npu_dev_run.sh runs for one R2 load: start llama-server with the
#   arguments given, wait until it is ready, run one short greedy generation, stop the server cleanly. Proposed for
#   review with k5-r2/README.txt; it runs only under npu_dev_run.sh and only after the owner approves R2.
#
#   r2_load_probe.sh <new out dir> <port> <ready timeout s> -- <llama-server> [server args...]
#
# Exit 0 only if: the server answered /health within the ready timeout, POST /completion (a fixed prompt, n_predict 32,
# temperature 0, top_k 1, seed 1) returned 200 with 1..32 predicted tokens and finite timings, and the server then
# exited on SIGTERM within 60 s with status 0 or 143 (it was still running when asked; it is reaped). Output in <out dir>:
# server.log (the server's stdout and stderr, -lv 4 expected), generation.json (the response), probe.txt (one line per
# step). Any failure, and any exit path including a signal from the wrapper: the server is stopped and reaped, exit 1.
set -uo pipefail
OUT=$1 PORT=$2 READY=$3; shift 3; [ "${1:-}" = -- ] && shift
[[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$READY" =~ ^[0-9]+$ ]] && [ $# -gt 0 ] || { echo "usage error" >&2; exit 2; }
[ ! -e "$OUT" ] && mkdir -p "$OUT" || { echo "$OUT exists or cannot be created (every probe writes a new directory)" >&2; exit 2; }
say() { echo "$(date -Is) $*" | tee -a "$OUT/probe.txt"; }
"$@" --host 127.0.0.1 --port "$PORT" > "$OUT/server.log" 2>&1 &
SPID=$!; say "server pid $SPID"; STOPPED=0
# stop(): the server must still be running when asked to stop (an earlier exit is a failure, with its status), must
# exit within 60 s of SIGTERM (else SIGKILL, a failure), and is reaped with its exit status recorded (review of fdb7292)
stop() { local i st
  [ "$STOPPED" = 1 ] && return 0; STOPPED=1
  if ! kill -0 "$SPID" 2>/dev/null; then wait "$SPID" 2>/dev/null; st=$?; say "server had already exited (status $st) before shutdown"; return 1; fi
  kill -TERM "$SPID" 2>/dev/null
  for i in $(seq 1 60); do kill -0 "$SPID" 2>/dev/null || break; sleep 1; done
  if kill -0 "$SPID" 2>/dev/null; then say "server did not exit within 60 s of SIGTERM"; kill -KILL "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null; return 1; fi
  wait "$SPID" 2>/dev/null; st=$?; say "server exited on SIGTERM (status $st)"
  [ "$st" = 0 ] || [ "$st" = 143 ]; }
# on every exit path (an error, a signal from the wrapper) the server is stopped and reaped
trap 'stop > /dev/null 2>&1' EXIT; trap 'say "probe interrupted"; stop; exit 1' INT TERM HUP
# readiness by wall clock (as b1_t5_payload.sh, review of e156439): each /health request is capped at the time left
# (at most 5 s), so a server that accepts the connection but never answers cannot hold the probe past READY seconds
up=0; T0=$SECONDS; DL=$((SECONDS + READY))
while [ "$SECONDS" -lt "$DL" ]; do
  kill -0 "$SPID" 2>/dev/null || { wait "$SPID" 2>/dev/null; say "server exited before ready (status $?)"; STOPPED=1; exit 1; }
  rem=$((DL - SECONDS)); [ "$rem" -gt 5 ] && rem=5; [ "$rem" -lt 1 ] && break
  curl -fs --connect-timeout "$rem" --max-time "$rem" "http://127.0.0.1:$PORT/health" > /dev/null 2>&1 \
    && { up=1; say "ready after $((SECONDS - T0)) s"; break; }
  [ "$SECONDS" -lt "$DL" ] && sleep 1
done
[ "$up" = 1 ] || { say "not ready after $READY s"; stop; exit 1; }
body='{"prompt": "The capital of France is", "n_predict": 32, "temperature": 0, "top_k": 1, "seed": 1, "cache_prompt": false}'
code=$(curl -s -o "$OUT/generation.json" -w '%{http_code}' -H 'Content-Type: application/json' -d "$body" \
       --max-time 600 "http://127.0.0.1:$PORT/completion") || code=000
ok=$(python3 -I - "$OUT/generation.json" <<'PY'
import json, math, sys
try:
    r = json.load(open(sys.argv[1])); t = r.get("timings", {}); n = t.get("predicted_n")
    good = isinstance(n, int) and 1 <= n <= 32 and all(isinstance(t.get(k), (int, float)) and math.isfinite(t[k])
                                                        for k in ("prompt_ms", "predicted_ms"))
    print("yes" if good else "no")
except Exception:
    print("no")
PY
)
say "generation: http $code, valid $ok"
stop; st=$?
[ "$code" = 200 ] && [ "$ok" = yes ] && [ "$st" = 0 ] || { say "PROBE FAIL"; exit 1; }
say "PROBE OK"; exit 0
