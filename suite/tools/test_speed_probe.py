"""Tests for speed_probe.py: canned SSE streams from a local server, in both "data:" spacings."""
import http.server, importlib.util, json, os, threading, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sp", os.path.join(HERE, "speed_probe.py"))
sp = importlib.util.module_from_spec(spec); spec.loader.exec_module(sp)
PREFIX = {}


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        pre = PREFIX["now"]
        for i in range(40):
            ev = {"choices": [{"index": 0, "delta": {"content": f"t{i} "}, "finish_reason": None}]}
            self.wfile.write(pre + json.dumps(ev).encode() + b"\n\n")
        usage = {"choices": [], "usage": {"prompt_tokens": 500, "completion_tokens": 40},
                 "timings": {"prompt_per_second": 60.0, "predicted_per_second": 8.0}}
        self.wfile.write(pre + json.dumps(usage).encode() + b"\n\n")
        self.wfile.write(pre + b"[DONE]\n\n")

    def log_message(self, *a):
        pass


class SpeedProbeSSE(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.srv.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()

    def check(self, prefix):
        PREFIX["now"] = prefix
        res, _ = sp.measure(self.url, "m", 512, 40, 3.2)
        self.assertNotIn("ERROR", res)
        self.assertIn("prompt_tokens=500", res)
        self.assertIn("gen_tokens=40", res)
        self.assertIn("method=usage", res)
        self.assertIn("server_decode_tps=8.00", res)

    def test_data_with_space(self):          # llama-server: "data: {...}" and "data: [DONE]"
        self.check(b"data: ")

    def test_data_without_space(self):       # GenieX serve: "data:{...}" and "data:[DONE]"
        self.check(b"data:")


if __name__ == "__main__":
    unittest.main()
