#!/usr/bin/env python3
"""offline tests for r1_t5_screen.py (NPU dev plan T5/T7): the call checker on crafted replies, and whole runs against a
local fake server (loopback, a thread in this process) for the fresh-trial and fail-closed rules. No model."""
import http.server, json, os, shutil, subprocess, sys, tempfile, threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import r1_t5_screen as t5

REQ = os.path.join(HERE, "..", "k5-t7", "t5-requests.json")
doc = json.load(open(REQ))
fails = 0


def ok(name, cond, detail=""):
    global fails
    print(f"{'ok  ' if cond else 'FAIL'} {name}")
    if not cond:
        fails += 1; print("     ", detail)


def reply(name, args, cid="call_1", typ="function", raw=None, n=1):
    call = {"id": cid, "type": typ, "function": {"name": name, "arguments": raw if raw is not None else json.dumps(args)}}
    return {"choices": [{"message": {"role": "assistant", "content": "", "tool_calls": [call] * n}}]}


exp = lambda i: doc["requests"][i]["expected"]
chk = lambda resp, i: t5.check_call(resp, doc["tools"], exp(i), doc["value_modes"])
# r01 weather Lisbon celsius; r03 run_command nows; r05 calculate nows; r06 convert num
ok("correct call passes", chk(reply("get_weather", {"city": "Lisbon", "unit": "celsius"}), 0) == [])
ok("case-insensitive city passes (ci)", chk(reply("get_weather", {"city": " lisbon ", "unit": "celsius"}), 0) == [])
ok("wrong enum value fails", chk(reply("get_weather", {"city": "Lisbon", "unit": "kelvin"}), 0) != [])
ok("wrong tool fails", chk(reply("search_web", {"query": "weather Lisbon"}), 0) != [])
ok("missing required argument fails", chk(reply("get_weather", {"city": "Lisbon"}), 0) != [])
ok("extra argument fails", chk(reply("get_weather", {"city": "Lisbon", "unit": "celsius", "days": "1"}), 0) != [])
ok("wrong value fails", chk(reply("get_weather", {"city": "Porto", "unit": "celsius"}), 0) != [])
ok("two calls fail", chk(reply("get_weather", {"city": "Lisbon", "unit": "celsius"}, n=2), 0) != [])
ok("no call fails", chk({"choices": [{"message": {"role": "assistant", "content": "It is sunny."}}]}, 0) != [])
ok("missing id fails", chk(reply("get_weather", {"city": "Lisbon", "unit": "celsius"}, cid=""), 0) != [])
ok("wrong type fails", chk(reply("get_weather", {"city": "Lisbon", "unit": "celsius"}, typ="tool"), 0) != [])
ok("unparseable arguments fail", chk(reply("get_weather", None, raw="{city: Lisbon"), 0) != [])
ok("non-object arguments fail", chk(reply("get_weather", None, raw="[1, 2]"), 0) != [])
ok("non-string argument fails", chk(reply("get_weather", {"city": 7, "unit": "celsius"}), 0) != [])
ok("whitespace-insensitive command passes (nows)", chk(reply("run_command", {"command": "ls  -la /tmp"}), 2) == [])
ok("different command fails", chk(reply("run_command", {"command": "ls -l /tmp"}), 2) != [])
ok("expression with spaces passes (nows)", chk(reply("calculate", {"expression": "17 * 23"}), 4) == [])
ok("numeric amount 250.0 passes (num)", chk(reply("convert_currency", {"amount": 250.0, "from": "EUR", "to": "USD"}), 5) == [])
ok("string amount fails", chk(reply("convert_currency", {"amount": "250", "from": "EUR", "to": "USD"}), 5) != [])
ok("boolean amount fails", chk(reply("convert_currency", {"amount": True, "from": "EUR", "to": "USD"}), 5) != [])
ok("currency outside the enum fails", chk(reply("convert_currency", {"amount": 250, "from": "euro", "to": "USD"}), 5) != [])


class Fake(http.server.BaseHTTPRequestHandler):
    mode = "good"; erase_status = 200; seen_erase = 0

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = json.loads(self.rfile.read(n) or b"null")
        if self.path.startswith("/slots/0?action=erase"):
            Fake.seen_erase += 1
            self.send_response(Fake.erase_status); self.end_headers(); self.wfile.write(b'{"n_erased": 0}'); return
        user = body["messages"][1]["content"]
        r = next(r for r in doc["requests"] if r["user"] == user)
        e = r["expected"]; args = {}
        props = next(t["function"]["parameters"]["properties"] for t in doc["tools"] if t["function"]["name"] == e["tool"])
        for k, (m, v) in e["values"].items():
            args[k] = v
        for k in props:
            args.setdefault(k, "x")
        if Fake.mode == "fail3" and r["id"] in ("r01", "r02", "r03"):
            args = {}
        resp = reply(e["tool"], args)
        resp["usage"] = {"prompt_tokens": 500}
        resp["timings"] = {"cache_n": 0, "prompt_n": 500}
        if Fake.mode == "cached" and r["id"] == "r05":
            resp["timings"] = {"cache_n": 120, "prompt_n": 380}
        if Fake.mode == "short" and r["id"] == "r07":
            resp["timings"] = {"cache_n": 0, "prompt_n": 499}
        if Fake.mode == "notimings" and r["id"] == "r02":
            del resp["timings"]
        out = json.dumps(resp).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(out)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{srv.server_address[1]}"
tmp = tempfile.mkdtemp()


def run(mode, erase_status=200):
    Fake.mode, Fake.erase_status, Fake.seen_erase = mode, erase_status, 0
    p = subprocess.run([sys.executable, "-I", os.path.join(HERE, "r1_t5_screen.py"), "--server", url, "--requests", REQ,
                        "--out", tmp, "--label", mode], capture_output=True, text=True)
    return p.returncode, open(os.path.join(tmp, f"{mode}-summary.txt")).read().strip()


rc, s = run("good"); ok("all-correct run: rc 0, 20/20, an erase before every trial", rc == 0 and "passes 20/20, valid 20/20" in s and Fake.seen_erase == 20, s)
rc, s = run("fail3"); ok("three wrong calls: rc 0 (valid run), 17/20", rc == 0 and "passes 17/20, valid 20/20" in s, s)
rc, s = run("cached"); ok("a trial with cache_n > 0 makes the run invalid (rc 3)", rc == 3 and "INVALID RUN" in s, s)
rc, s = run("short"); ok("prompt_n below prompt_tokens makes the run invalid (rc 3)", rc == 3 and "INVALID RUN" in s, s)
rc, s = run("notimings"); ok("missing timings make the run invalid (rc 3)", rc == 3 and "INVALID RUN" in s, s)
rc, s = run("erase500", erase_status=500); ok("a failed slot erase makes the run invalid (rc 3)", rc == 3 and "INVALID RUN" in s, s)
srv.shutdown(); shutil.rmtree(tmp)
p = subprocess.run([sys.executable, "-I", os.path.join(HERE, "r1_t5_screen.py"), "--server", "http://127.0.0.1:9",
                    "--requests", REQ, "--out", tempfile.mkdtemp(), "--label", "down"], capture_output=True, text=True)
ok("no server: rc 3", p.returncode == 3)
print(f"failures: {fails}"); sys.exit(fails)
