"""Tests for probe_toolcalls.py --stream: canned SSE streams from a local server."""
import http.server, importlib.util, json, os, threading, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("p", os.path.join(HERE, "probe_toolcalls.py"))
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
STREAMS = {}


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for ev in STREAMS["now"]:
            self.wfile.write(b"data: " + json.dumps(ev).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


def tc(index=0, id=None, name=None, args=None):
    f = {}
    if name is not None: f["name"] = name
    if args is not None: f["arguments"] = args
    d = {"index": index, "function": f}
    if id is not None: d["id"] = id
    return d


def ev(delta=None, finish=None):
    return {"choices": [{"delta": delta or {}, "finish_reason": finish}]}


class Stream(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.srv.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown(); cls.srv.server_close()

    def run_stream(self, events):
        STREAMS["now"] = events
        r, issues = p.stream_call(self.url, {"messages": [], "tools": p.TOOLS})
        return ("stream-defect" if issues else p.classify(r)), r, issues

    def test_call_split_across_deltas_passes(self):
        cls, r, _ = self.run_stream([
            ev({"tool_calls": [tc(id="c1", name="bash", args='{"comm')]}),
            ev({"tool_calls": [tc(args='and": "ls')]}),
            ev({"tool_calls": [tc(args=' -la"}')]}),
            ev(finish="tool_calls")])
        self.assertEqual(cls, "pass")
        self.assertEqual(r["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"], '{"command": "ls -la"}')

    def test_name_repeated_in_every_delta_keeps_the_first_like_pi(self):
        cls, r, _ = self.run_stream([
            ev({"tool_calls": [tc(id="c1", name="bash", args='{"command":')]}),
            ev({"tool_calls": [tc(name="bash", args=' "ls"}')]}),
            ev(finish="tool_calls")])
        self.assertEqual(cls, "pass"); self.assertEqual(r["choices"][0]["message"]["tool_calls"][0]["function"]["name"], "bash")

    def test_missing_id_is_a_defect(self):
        cls, _, issues = self.run_stream([ev({"tool_calls": [tc(name="bash", args='{"command": "ls"}')]}), ev(finish="tool_calls")])
        self.assertEqual(cls, "stream-defect"); self.assertIn("call 0: no id", issues)

    def test_no_finish_reason_is_a_defect(self):
        cls, _, issues = self.run_stream([ev({"tool_calls": [tc(id="c1", name="bash", args='{"command": "ls"}')]})])
        self.assertEqual(cls, "stream-defect"); self.assertTrue(any("finish_reason" in i for i in issues))

    def test_delta_after_finish_is_a_defect(self):
        cls, _, _ = self.run_stream([
            ev({"tool_calls": [tc(id="c1", name="bash", args='{"command": "ls"}')]}), ev(finish="tool_calls"),
            ev({"content": "late text"})])
        self.assertEqual(cls, "stream-defect")

    def test_text_only_reply_is_no_call(self):
        cls, _, _ = self.run_stream([ev({"content": "I would list the files."}), ev(finish="stop")])
        self.assertEqual(cls, "no-call")

    def test_two_parallel_calls_by_index(self):
        cls, r, _ = self.run_stream([
            ev({"tool_calls": [tc(0, "a", "bash", '{"command": "ls"}'), tc(1, "b", "bash", '{"command": ')]}),
            ev({"tool_calls": [tc(1, args='"pwd"}')]}), ev(finish="tool_calls")])
        self.assertEqual(cls, "pass"); self.assertEqual(len(r["choices"][0]["message"]["tool_calls"]), 2)


if __name__ == "__main__":
    unittest.main()
