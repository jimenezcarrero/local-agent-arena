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
        if mode in ("slowstart", "slowhead"):
            time.sleep(6 if mode == "slowstart" else 4); mode = "tool"
        if mode == "malformed":
            self.send_response(200); self.send_header("Connection", "close"); self.end_headers()
            self.wfile.write(b"data: {not json\n\n"); self.close_connection = True; return
        if mode == "error":
            self.send_response(500); self.send_header("Content-Length", "0"); self.end_headers(); return
        if mode == "json":
            b = json.dumps({"choices": [{"finish_reason": "tool_calls", "message": {"content": "", "tool_calls": [{"id": "a", "function": {"name": "read", "arguments": "{}"}}]}}]}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b); return
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Connection", "close"); self.end_headers()
        self.close_connection = True
        ev = [{"choices": [{"delta": {"reasoning_content": "think "}}]}]
        frag = {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c1", "function": {"name": "read", "arguments": "{\"pa"}}]}}]}
        if mode in ("trunc", "partial"):
            for e in ev + [frag]:
                self.wfile.write(b"data: " + json.dumps(e).encode() + b"\n\n"); self.wfile.flush()
            if mode == "partial":
                time.sleep(4)
            return
        if mode == "badargs":
            ev += [{"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c1", "function": {"name": "read", "arguments": "not json"}}]}}]},
                   {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}]
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
# replay: each outcome class
def replay(mode, n=2, extra=None, port=None, out=None):
    rq = os.path.join(T, f"{mode}.json"); open(rq, "w").write(json.dumps({"mode": mode, "stream": mode != "json"}))
    out = out or os.path.join(T, f"r-{mode}-{port or up}")
    env = dict(os.environ, TIMEOUT_S="2"); env.update(extra or {})
    pr = subprocess.run([sys.executable, os.path.join(D, "replay_first.py"), rq, str(port or up), str(n), out, mode], capture_output=True, text=True, env=env)
    if pr.returncode == 2: return pr.returncode, pr.stdout.strip(), []
    if pr.returncode not in (0, 1) or not os.path.exists(os.path.join(out, "replay.jsonl")): print(pr.stderr[-800:])
    rows = [json.loads(l) for l in open(os.path.join(out, "replay.jsonl"))]
    return pr.returncode, pr.stdout.strip(), rows
rc, out, rows = replay("tool", n=1, port=px); check("replay through the proxy (chunked) -> tool, rc 0", rc == 0 and "tool calls 1/1" in out, out)
p.terminate()
rc, out, rows = replay("tool"); check("replay tool -> 2/2, rc 0", rc == 0 and "tool calls 2/2" in out and rows[0]["tool_calls"] == 1, out)
rc, out, rows = replay("no_tool"); check("replay no_tool -> 0/2, content kept, rc 0", rc == 0 and "tool calls 0/2 (no_tool 2" in out and "reported" in rows[0]["content_head"], out)
rc, out, rows = replay("stall", n=1); check("replay stall -> timeout, rc 0", rc == 0 and "timeout 1" in out and rows[0]["outcome"] == "timeout", out)
rc, out, rows = replay("error", n=1); check("replay HTTP 500 -> error, rc 1", rc == 1 and "error 1" in out, out)
rc, out, rows = replay("json", n=1); check("replay plain JSON with tool_calls -> tool", rc == 0 and "tool calls 1/1" in out, out)
# D142 (Codex review of 15c6fa6): incomplete/malformed replies are errors (rc 1); one total deadline; partial output kept
rc, out, rows = replay("trunc", n=1); check("truncated tool fragment, no finish/[DONE] -> error, rc 1", rc == 1 and "error 1" in out and rows[0]["tool_fragments"] == 1, out)
rc, out, rows = replay("malformed", n=1); check("malformed HTTP-200 body -> error, rc 1", rc == 1 and "error 1" in out, out)
rc, out, rows = replay("badargs", n=1); check("tool call with non-JSON arguments -> error, rc 1", rc == 1 and "error 1" in out, out)
rc, out, rows = replay("slowstart", n=1, extra={"TIMEOUT_S": "20"}); check("6 s quiet before headers, then success -> tool", rc == 0 and "tool calls 1/1" in out, out)
rc, out, rows = replay("slowhead", n=1); check("deadline (2 s) before headers -> timeout, rc 0", rc == 0 and "timeout 1" in out, out)
rc, out, rows = replay("partial", n=1); check("deadline during SSE -> timeout, partial fragment kept", rc == 0 and "timeout 1" in out and rows[0]["tool_fragments"] == 1 and rows[0]["reasoning_chars"] > 0, out)
d0 = os.path.join(T, "stale"); os.makedirs(d0)
rc, out, rows = replay("tool", n=1, out=d0); check("existing output directory -> refused, rc 2", rc == 2 and "refusing" in out, out)
srv.shutdown()
print(f"failures: {fails}"); sys.exit(fails)
