#!/bin/bash
# offline tests for b1_t5_payload.sh: a fake llama-server (loopback Python; modes by FAKE_MODE) and a stub screen
# (B1_T5_SCREEN; its exit code by STUB_RC), plus one case with the real r1_t5_screen.py against the fake (invalid run)
D=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; fails=0; n=0
cat > "$W/fake.py" <<'PY'
import http.server, json, os, signal, sys, time
a = sys.argv[1:]; port = int(a[a.index("--port") + 1]); mode = os.environ.get("FAKE_MODE", "good")
if mode == "early": sys.exit(1)
if mode == "noterm": signal.signal(signal.SIGTERM, signal.SIG_IGN)
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *x): pass
    def do_GET(self):
        if mode == "hang": time.sleep(60)   # accepts /health and never answers within the readiness window
        self.send_response(200 if mode != "never" else 503); self.end_headers(); self.wfile.write(b"{}")
        if mode == "dies" and self.path == "/health" and os.environ.get("DIE_NOW"): os._exit(3)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); self.rfile.read(n)
        r = {"choices": [{"message": {"role": "assistant", "content": "no tool"}, "finish_reason": "stop"}]}
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(r).encode())
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
cat > "$W/stub.py" <<'PY'
import os, sys, urllib.request
a = sys.argv[1:]; srv = a[a.index("--server") + 1]
if os.environ.get("FAKE_MODE") == "dies":   # the server exits during the screen (before the payload stops it)
    os.environ["DIE_NOW"] = "1"
    try: urllib.request.urlopen(srv + "/health?die", timeout=5)
    except Exception: pass
rc = int(os.environ.get("STUB_RC", "0"))
print(f"T5 stub: passes 20/20, valid 20/20" if rc == 0 else "T5 stub: INVALID"); sys.exit(rc)
PY
cat > "$W/speed.py" <<'PY2'
import os, sys
a = sys.argv[1:]; rc = int(os.environ.get("SPEED_RC", "0"))
open(a[1], "a").write("SUMMARY stub: all depths measured\n" if rc == 0 else "SUMMARY stub: 1 depth(s) FAILED\n"); sys.exit(rc)
PY2
run() { local out=$1 mode=$2 rc=$3 scr=$4; shift 4
  FAKE_MODE=$mode STUB_RC=$rc B1_T5_SCREEN=$scr timeout 300 bash "$D/b1_t5_payload.sh" "$out" $((30000 + RANDOM % 20000)) 5 stub 30 "$@" \
    -- python3 -I "$W/fake.py" > /dev/null 2>&1; }
expect() { local name=$1 want=$2 mode=$3 rc=${4:-0} scr=${5:-$W/stub.py}; n=$((n + 1))
  run "$W/o$n" "$mode" "$rc" "$scr"; got=$?
  [ "$got" = "$want" ] && echo "ok   $name (rc $got: $(tail -1 "$W/o$n/probe.txt" 2>/dev/null))" || { echo "FAIL $name (rc $got, wanted $want): $(tail -2 "$W/o$n/probe.txt" 2>/dev/null | tr '\n' ' ')"; fails=$((fails + 1)); }; }
expect "ready, valid screen, clean stop: OK" 0 good 0
expect "the screen reports an invalid run (exit 1): FAIL" 1 good 1
expect "never ready: FAIL" 1 never 0
expect "server exits before ready: FAIL" 1 early 0
expect "server ignores SIGTERM: FAIL" 1 noterm 0
# a /health that hangs (review of e156439): with READY 5 the payload must give up by the wall clock, not after 60 s
n=$((n + 1)); t0=$SECONDS; FAKE_MODE=hang STUB_RC=0 B1_T5_SCREEN="$W/stub.py" timeout 300 bash "$D/b1_t5_payload.sh" "$W/o$n" $((30000 + RANDOM % 20000)) 5 stub 30 -- python3 -I "$W/fake.py" > /dev/null 2>&1; got=$?; el=$((SECONDS - t0))
grep -q "not ready after 5 s" "$W/o$n/probe.txt" && [ "$got" = 1 ] && [ "$el" -lt 75 ] && echo "ok   /health hangs: not ready by the wall clock (rc $got, readiness gave up in time; whole run ${el} s incl. the stop)" || { echo "FAIL /health hangs (rc $got, ${el} s): $(tail -2 "$W/o$n/probe.txt" | tr '\n' ' ')"; fails=$((fails + 1)); }
expect "real r1_t5_screen.py against a server that answers without tool calls: FAIL (invalid or not passing)" 1 good 0 "$D/r1_t5_screen.py"
# the dies mode: the fake exits only when DIE_NOW is in ITS environment, so pass it at launch and let the stub hit /health
n=$((n + 1)); DIE_NOW=1 FAKE_MODE=good STUB_RC=0 B1_T5_SCREEN="$W/stub.py" timeout 300 bash "$D/b1_t5_payload.sh" "$W/o$n" $((30000 + RANDOM % 20000)) 5 stub 30 -- env FAKE_MODE=dies DIE_NOW=1 python3 -I "$W/fake.py" > /dev/null 2>&1; got=$?
[ "$got" = 1 ] && echo "ok   the server exits during the screen: FAIL (rc $got: $(tail -1 "$W/o$n/probe.txt"))" || { echo "FAIL server-dies case (rc $got): $(tail -2 "$W/o$n/probe.txt" | tr '\n' ' ')"; fails=$((fails + 1)); }
n=$((n + 1)); mkdir -p "$W/exists"; bash "$D/b1_t5_payload.sh" "$W/exists" 18000 5 stub 30 -- true > /dev/null 2>&1; got=$?
[ "$got" = 2 ] && echo "ok   an existing out dir: usage error (rc 2)" || { echo "FAIL existing out dir (rc $got)"; fails=$((fails + 1)); }
n=$((n + 1)); bash "$D/b1_t5_payload.sh" "$W/bad" 18000 5 'bad label' 30 -- true > /dev/null 2>&1; got=$?
[ "$got" = 2 ] && echo "ok   a label with a space: usage error (rc 2)" || { echo "FAIL bad label (rc $got)"; fails=$((fails + 1)); }
# --speed (B1d-4B): the speed probe runs after a valid screen; its exit status counts
sexpect() { local name=$1 want=$2 src=$3 srv=$4 depths=$5; shift 5; n=$((n + 1))
  env "$@" FAKE_MODE=good B1_T5_SCREEN="$W/stub.py" B1_SPEED_PROBE="$src" timeout 300 bash "$D/b1_t5_payload.sh" --speed "$depths" "$W/o$n" \
    $((30000 + RANDOM % 20000)) 5 stub 30 -- python3 -I "$W/fake.py" > /dev/null 2>&1; got=$?
  [ "$got" = "$want" ] && echo "ok   $name (rc $got: $(tail -1 "$W/o$n/probe.txt" 2>/dev/null))" || { echo "FAIL $name (rc $got, wanted $want): $(tail -2 "$W/o$n/probe.txt" 2>/dev/null | tr '\n' ' ')"; fails=$((fails + 1)); }; }
sexpect "--speed, screen and probe exit 0: OK" 0 "$W/speed.py" good 1024,28672 SPEED_RC=0 STUB_RC=0
grep -q "speed exit 0: SUMMARY stub: all depths measured" "$W/o$n/probe.txt" && echo "ok   --speed records the probe's summary in probe.txt" || { echo "FAIL --speed summary not recorded"; fails=$((fails + 1)); }; n=$((n + 1))
sexpect "--speed, the probe fails a depth (exit 1): FAIL" 1 "$W/speed.py" good 1024 SPEED_RC=1 STUB_RC=0
sexpect "--speed, the screen is invalid: FAIL and the probe does not run" 1 "$W/speed.py" good 1024 SPEED_RC=0 STUB_RC=1
[ ! -e "$W/o$n/speed.console" ] && echo "ok   --speed: no probe after an invalid screen" || { echo "FAIL the probe ran after an invalid screen"; fails=$((fails + 1)); }; n=$((n + 1))
sexpect "--speed with the real suite speed_probe.py against a server that streams nothing: FAIL" 1 "$D/../../../../suite/tools/speed_probe.py" good 1024 STUB_RC=0
grep -q "ERROR" "$W/o$n/speed.txt" 2>/dev/null && echo "ok   the real probe recorded the depth as ERROR" || { echo "FAIL the real probe's ERROR line missing"; fails=$((fails + 1)); }; n=$((n + 1))
n=$((n + 1)); bash "$D/b1_t5_payload.sh" --speed 1024,x "$W/bad2" 18000 5 stub 30 -- true > /dev/null 2>&1; got=$?
[ "$got" = 2 ] && [ ! -e "$W/bad2" ] && echo "ok   --speed with a malformed depth list: usage error (rc 2)" || { echo "FAIL malformed depths (rc $got)"; fails=$((fails + 1)); }
echo "failures: $fails of $n"; exit $fails
