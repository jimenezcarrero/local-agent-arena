#!/usr/bin/env python3
"""Mock OpenAI-compatible server for measuring pi's own memory: scripted tool calls (bash pytest, read the largest
file), then a final answer. Streams SSE like llama-server. Port 8080."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
N = int(sys.argv[2]) if len(sys.argv) > 2 else 1
SCRIPT = [("bash", {"command": "python3 -m pytest tests/ -q -p no:cacheprovider 2>&1 | tail -5"})] + [("read", {"path": sys.argv[1]})] * N + [("bash", {"command": "ls -la; wc -l *.py"}), None]
state = {"turn": 0}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"data": [{"id": "local32k"}]}).encode(); self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        nmsg = len(req.get("messages", [])); step = SCRIPT[min(state["turn"], len(SCRIPT) - 1)]; state["turn"] += 1
        print(f"{time.strftime('%H:%M:%S')} request messages={nmsg} bytes={len(json.dumps(req))} -> {step[0] if step else 'final'}", flush=True)
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        def ev(d): self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\n"); self.wfile.flush()
        base = {"id": "x", "object": "chat.completion.chunk", "created": 0, "model": "local32k"}
        if step:
            ev({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [{"index": 0, "id": f"c{state['turn']}", "type": "function",
                "function": {"name": step[0], "arguments": json.dumps(step[1])}}]}, "finish_reason": None}]})
            ev({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
        else:
            ev({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": "Done. 3 failed, 40 passed."}, "finish_reason": None}]})
            ev({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        ev({**base, "choices": [], "usage": {"prompt_tokens": 1000, "completion_tokens": 20, "total_tokens": 1020}})
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
ThreadingHTTPServer(("127.0.0.1", 8080), H).serve_forever()
