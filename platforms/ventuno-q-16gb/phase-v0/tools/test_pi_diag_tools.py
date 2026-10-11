#!/usr/bin/env python3
"""Offline tests for pi_capture_proxy.py and replay_first.py (D141): a fake upstream server on localhost answers
/health and /v1/chat/completions (SSE with a tool call, SSE without one, a stall, HTTP 500, plain JSON), selected by the
request's "mode" field. Nothing touches the NPU or a real llama-server."""
import http.server, json, os, socket, subprocess, sys, tempfile, threading, time, urllib.request

D = os.path.dirname(os.path.abspath(__file__))
fails = 0


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


class Fake(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        b = b'{"status":"ok"}'; self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        mode = body.get("mode", "tool")
        if mode == "error":
            self.send_response(500); self.send_header("Content-Length", "0"); self.end_headers(); return
        if mode == "json":
            b = json.dumps({"choices": [{"finish_reason": "tool_calls", "message": {"content": "", "tool_calls": [{"id": "a"}]}}]}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        ev = [{"choices": [{"delta": {"reasoning_content": "think "}}]}]
        if mode == "tool":
            ev += [{"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c1", "function": {"name": "read", "arguments": ""}}]}}]},
                   {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "{}"}}]}}]},
                   {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}]
        elif mode == "no_tool":
            ev += [{"choices": [{"delta": {"content": "The read tool reported an error"}}]}, {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
        for e in ev:
            self.wfile.write(b"data: " + json.dumps(e).encode() + b"\n\n"); self.wfile.flush()
        if mode == "stall":
            try:
                for _ in range(100):
                    time.sleep(0.1); self.wfile.write(b": keepalive\n\n"); self.wfile.flush()
            except OSError:
                return
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush(); self.close_connection = True


def check(name, cond, info=""):
    global fails
    print(("ok   " if cond else "FAIL ") + name + (f" ({info})" if info else "")); fails += 0 if cond else 1


up = free_port(); srv = http.server.ThreadingHTTPServer(("127.0.0.1", up), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
T = tempfile.mkdtemp()
# proxy: relays, records chat requests only
px = free_port(); cap = os.path.join(T, "cap")
p = subprocess.Popen([sys.executable, os.path.join(D, "pi_capture_proxy.py"), str(px), str(up), cap])
for _ in range(50):
    try: urllib.request.urlopen(f"http://127.0.0.1:{px}/health", timeout=1); break
    except OSError: time.sleep(0.1)
h = urllib.request.urlopen(f"http://127.0.0.1:{px}/health").read()
check("proxy relays /health", b"ok" in h)
req = json.dumps({"mode": "tool", "stream": True, "messages": [{"role": "user", "content": "x"}]}).encode()
r = urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{px}/v1/chat/completions", data=req, headers={"Content-Type": "application/json"})).read()
check("proxy relays the SSE body", b"[DONE]" in r and b"tool_calls" in r)
time.sleep(0.3)
files = sorted(os.listdir(cap))
check("proxy records request/response/meta for the chat call only", files == ["0001-meta.json", "0001-request.json", "0001-response.txt"], str(files))
check("recorded request is byte-identical", open(os.path.join(cap, "0001-request.json"), "rb").read() == req)
check("recorded response holds the stream", b"[DONE]" in open(os.path.join(cap, "0001-response.txt"), "rb").read())
p.terminate()
# replay: each outcome class
def replay(mode, n=2, extra=None):
    rq = os.path.join(T, f"{mode}.json"); open(rq, "w").write(json.dumps({"mode": mode, "stream": mode != "json"}))
    out = os.path.join(T, f"r-{mode}")
    env = dict(os.environ, TIMEOUT_S="2", **(extra or {}))
    pr = subprocess.run([sys.executable, os.path.join(D, "replay_first.py"), rq, str(up), str(n), out, mode], capture_output=True, text=True, env=env)
    if pr.returncode not in (0, 1) or not os.path.exists(os.path.join(out, "replay.jsonl")): print(pr.stderr[-800:])
    rows = [json.loads(l) for l in open(os.path.join(out, "replay.jsonl"))]
    return pr.returncode, pr.stdout.strip(), rows
rc, out, rows = replay("tool"); check("replay tool -> 2/2, rc 0", rc == 0 and "tool calls 2/2" in out and rows[0]["tool_calls"] == 1, out)
rc, out, rows = replay("no_tool"); check("replay no_tool -> 0/2, content kept, rc 0", rc == 0 and "tool calls 0/2 (no_tool 2" in out and "reported" in rows[0]["content_head"], out)
rc, out, rows = replay("stall", n=1); check("replay stall -> timeout, rc 0", rc == 0 and "timeout 1" in out and rows[0]["outcome"] == "timeout", out)
rc, out, rows = replay("error", n=1); check("replay HTTP 500 -> error, rc 1", rc == 1 and "error 1" in out, out)
rc, out, rows = replay("json", n=1); check("replay plain JSON with tool_calls -> tool", rc == 0 and "tool calls 1/1" in out, out)
srv.shutdown()
print(f"failures: {fails}"); sys.exit(fails)
