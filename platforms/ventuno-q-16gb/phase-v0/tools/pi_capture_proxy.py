#!/usr/bin/env python3
"""pi_capture_proxy.py <listen port> <upstream port> <capture dir> (D141) — a transparent HTTP proxy on 127.0.0.1 for
the pi diagnostic: every request is forwarded unchanged to 127.0.0.1:<upstream port> and its response is relayed as it
arrives (server-sent events included). Each POST to /v1/chat/completions is recorded in <capture dir> as
NNNN-request.json (the exact body) and NNNN-response.txt (the raw response body bytes), with NNNN-meta.json (path,
status, start/end time). Other paths (/health, /props, /v1/models) are relayed without recording. Standard library only.
An upstream that is not up yet gives 502, so a readiness loop simply keeps waiting."""
import http.client, http.server, json, os, sys, threading, time

LOCK = threading.Lock()
COUNT = [0]


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def _relay(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        rec = method == "POST" and self.path.split("?")[0] == "/v1/chat/completions"
        idx = None
        if rec:
            with LOCK:
                COUNT[0] += 1; idx = COUNT[0]
            with open(os.path.join(CAP, f"{idx:04d}-request.json"), "wb") as f:
                f.write(body or b"")
        t0 = time.time()
        hdr = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection", "content-length")}
        try:
            c = http.client.HTTPConnection("127.0.0.1", UP, timeout=3600)
            c.request(method, self.path, body=body, headers=hdr)
            r = c.getresponse()
        except OSError:
            self.send_response(502); self.send_header("Content-Length", "0"); self.end_headers(); return
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        out = open(os.path.join(CAP, f"{idx:04d}-response.txt"), "wb") if rec else None
        try:
            while True:
                chunk = r.read1(65536)
                if not chunk:
                    break
                if out:
                    out.write(chunk); out.flush()
                try:
                    self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk)); self.wfile.flush()
                except OSError:
                    break  # client gone (pi cancelled); keep nothing else to relay
            try:
                self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            except OSError:
                pass
        finally:
            if out:
                out.close()
                with open(os.path.join(CAP, f"{idx:04d}-meta.json"), "w") as f:
                    json.dump({"path": self.path, "status": r.status, "start": t0, "end": time.time()}, f)
            c.close()

    def do_GET(self):
        self._relay("GET")

    def do_POST(self):
        self._relay("POST")


if __name__ == "__main__":
    port, UP, CAP = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    os.makedirs(CAP, exist_ok=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Proxy).serve_forever()
