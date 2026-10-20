#!/bin/bash
# b1_t5_payload.sh (NPU dev plan B1c-4B Step 3): the payload npu_dev_run.sh runs for one T5 arm on the NPU: start
#   llama-server with the arguments given, wait until it is ready, run the frozen T5 screen (r1_t5_screen.py from this
#   directory, k5-t7/t5-requests.json) against it, stop the server cleanly. Proposed for review with b1c-4b/SPEC.txt;
#   it runs only under npu_dev_run.sh and only after the owner's approval of Step 3.
#
#   b1_t5_payload.sh [--speed <depths> [--min-pass <N>]] <new out dir> <port> <ready timeout s> <label> <per-request timeout s> \
#                    -- <llama-server> [args...]
#
# --speed (B1d-4B, b1d-4b/SPEC.txt): after a valid screen, the suite's speed probe (suite/tools/speed_probe.py from this
# checkout; B1_SPEED_PROBE overrides it, tests only) measures prefill and decode at each depth (comma-separated prompt
# token counts, 128 generated) on the same server; its RESULT lines go to speed.txt and its output to speed.console.
# The payload is then OK only if the probe also exited 0 (every depth measured). Without --speed nothing changes.
# --min-pass (review of 09a7a43, B1d's first-failure rule): the screen's last line must read "passes P/20, valid
# 20/20" with P >= N before the probe starts; a lower or unreadable score is a payload FAIL and the probe does not run.
#
# Exit 0 only if: the server answered /health within the ready timeout, the screen exited 0 (a valid run: all 20 trials
# valid; it exits 0 whatever the pass count, which the stage reads from screen.console), and the server then exited on
# SIGTERM within 60 s with status 0 or 143. Output in <out dir>: server.log, screen/ (the screen's trial records),
# screen.console (its output; the last line is "T5 <label>: passes P/20, valid 20/20" or the reason it is invalid),
# probe.txt (one line per step). Any failure, and any exit path including a signal from the wrapper: the server is
# stopped and reaped, exit 1. B1_T5_SCREEN overrides the screen's path (tests only).
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
SCREEN=${B1_T5_SCREEN:-$D/r1_t5_screen.py}; REQ=$D/../k5-t7/t5-requests.json
SPEED=${B1_SPEED_PROBE:-$D/../../../../suite/tools/speed_probe.py}; DEPTHS=; MINP=
if [ "${1:-}" = --speed ]; then DEPTHS=${2:-}; shift 2 || { echo "usage error" >&2; exit 2; }
  [[ "$DEPTHS" =~ ^[0-9]+(,[0-9]+)*$ ]] && [ -f "$SPEED" ] || { echo "usage error (--speed <depths>, probe $SPEED)" >&2; exit 2; }
  if [ "${1:-}" = --min-pass ]; then MINP=${2:-}; shift 2 || { echo "usage error" >&2; exit 2; }
    [[ "$MINP" =~ ^[0-9]+$ ]] && [ "$MINP" -le 20 ] || { echo "usage error (--min-pass 0..20)" >&2; exit 2; }; fi; fi
OUT=$1 PORT=$2 READY=$3 LABEL=$4 RTO=$5; shift 5; [ "${1:-}" = -- ] && shift
[[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$READY" =~ ^[0-9]+$ ]] && [[ "$RTO" =~ ^[0-9]+$ ]] && [[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] \
  && [ $# -gt 0 ] || { echo "usage error" >&2; exit 2; }
[ ! -e "$OUT" ] && mkdir -p "$OUT" || { echo "$OUT exists or cannot be created (every run writes a new directory)" >&2; exit 2; }
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
# readiness by wall clock (review of e156439): each /health request is capped at the time left (at most 5 s), so a
# server that accepts the connection but never answers cannot hold the payload past READY seconds
up=0; T0=$SECONDS; DL=$((SECONDS + READY))
while [ "$SECONDS" -lt "$DL" ]; do
  kill -0 "$SPID" 2>/dev/null || { wait "$SPID" 2>/dev/null; say "server exited before ready (status $?)"; STOPPED=1; exit 1; }
  rem=$((DL - SECONDS)); [ "$rem" -gt 5 ] && rem=5; [ "$rem" -lt 1 ] && break
  curl -fs --connect-timeout "$rem" --max-time "$rem" "http://127.0.0.1:$PORT/health" > /dev/null 2>&1 \
    && { up=1; say "ready after $((SECONDS - T0)) s"; break; }
  [ "$SECONDS" -lt "$DL" ] && sleep 1
done
[ "$up" = 1 ] || { say "not ready after $READY s"; stop; exit 1; }
python3 -I "$SCREEN" --server "http://127.0.0.1:$PORT" --requests "$REQ" --out "$OUT/screen" --label "$LABEL" \
  --timeout "$RTO" > "$OUT/screen.console" 2>&1; sc=$?
say "screen exit $sc: $(tail -1 "$OUT/screen.console")"
sp=0
if [ -n "$MINP" ] && [ "$sc" = 0 ]; then
  P=$(tail -1 "$OUT/screen.console" | sed -nE 's/.*: passes ([0-9]+)\/20, valid 20\/20$/\1/p')
  if [ -z "$P" ] || [ "$P" -lt "$MINP" ]; then say "screen score ${P:-unreadable} below --min-pass $MINP: no speed probe"; sp=1; fi
fi
if [ -n "$DEPTHS" ] && [ "$sc" = 0 ] && [ "$sp" = 0 ]; then
  python3 -I "$SPEED" "$LABEL" "$OUT/speed.txt" --depths "$DEPTHS" --gen 128 --url "http://127.0.0.1:$PORT" \
    > "$OUT/speed.console" 2>&1; sp=$?
  say "speed exit $sp: $(tail -1 "$OUT/speed.txt" 2>/dev/null)"
fi
stop; st=$?
[ "$sc" = 0 ] && [ "$sp" = 0 ] && [ "$st" = 0 ] || { say "PAYLOAD FAIL"; exit 1; }
say "PAYLOAD OK"; exit 0
