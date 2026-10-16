#!/bin/bash
# offline tests for r2_load_probe.sh with a fake llama-server (a loopback Python server; modes by FAKE_MODE)
D=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; fails=0; n=0
cat > "$W/fake.py" <<'PY'
import http.server, json, os, signal, sys, time
a = sys.argv[1:]; port = int(a[a.index("--port") + 1]); mode = os.environ.get("FAKE_MODE", "good")
if mode == "early": sys.exit(1)
if mode == "noterm": signal.signal(signal.SIGTERM, signal.SIG_IGN)
start = time.time()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *x): pass
    def do_GET(self):
        ready = mode != "never"
        self.send_response(200 if ready else 503); self.end_headers(); self.wfile.write(b"{}")
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); self.rfile.read(n)
        r = {"content": " Paris.", "timings": {"predicted_n": 0 if mode == "badgen" else 3, "prompt_ms": 10.0, "predicted_ms": 20.0}}
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(r).encode())
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
expect() { local name=$1 want=$2 mode=$3; n=$((n + 1))
  FAKE_MODE=$mode timeout 200 bash "$D/r2_load_probe.sh" "$W/o$n" $((30000 + RANDOM % 20000)) 5 -- python3 -I "$W/fake.py" > /dev/null 2>&1; rc=$?
  [ "$rc" = "$want" ] && echo "ok   $name (rc $rc: $(tail -1 "$W/o$n/probe.txt"))" || { echo "FAIL $name (rc $rc, wanted $want): $(tail -2 "$W/o$n/probe.txt" | tr '\n' ' ')"; fails=$((fails + 1)); }; }
expect "ready, generation, clean stop: OK" 0 good
expect "never ready: FAIL" 1 never
expect "server exits before ready: FAIL" 1 early
expect "generation with 0 tokens: FAIL" 1 badgen
expect "server ignores SIGTERM: FAIL (killed)" 1 noterm
# every probe recorded its server's pid: none may still run (checked by pid, never by a name pattern)
n=$((n + 1)); left=$(for p in $(cat "$W"/o*/probe.txt | sed -n 's/.* server pid \([0-9]*\)$/\1/p'); do kill -0 "$p" 2>/dev/null && echo "$p"; done)
if [ -n "$left" ]; then echo "FAIL servers left running: $left"; fails=$((fails + 1)); kill -KILL $left 2>/dev/null; else echo "ok   no server left running (each probe's recorded pid checked)"; fi
mkdir -p "$W/exists"; n=$((n + 1)); bash "$D/r2_load_probe.sh" "$W/exists" 30999 5 -- true > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && echo "ok   an existing out directory: refused (rc 2)" || { echo "FAIL an existing out directory (rc $rc)"; fails=$((fails + 1)); }
echo "failures: $fails of $n"; exit $fails
