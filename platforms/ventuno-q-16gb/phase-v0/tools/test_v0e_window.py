#!/usr/bin/env python3
"""offline tests for v0e_window.py cache mode (D117): post() replaced by a fake llama-server that answers /tokenize and
/v1/chat/completions; each case changes one thing and checks the exit code. No server, no network.
Usage: python3 test_v0e_window.py   (needs ~/v0/measure for the frozen corpus, as v0e_window.py does)"""
import copy, io, os, re, sys, tempfile
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v0e_window as vw


class Fake:
    """prompt tokens ~ characters / 3.2; cache_n = previous prompt when the first message is unchanged (same nonce)"""

    def __init__(self, **bad):
        self.bad, self.n, self.last, self.maxt = bad, 0, {}, []

    def __call__(self, path, body, timeout=0):
        if path == "/tokenize":
            return 200, {"tokens": [0] * int(len(body["content"]) / 3.2)}, 0.0
        self.n += 1; n = self.n; msgs = body["messages"]; self.maxt.append(body.get("max_tokens"))
        p = int(sum(len(m.get("content") or "") for m in msgs) / 3.2) + 40 * len(msgs)
        key = msgs[0]["content"][:60]; cn = self.last.get(key, 0) if self.last.get(key, 0) <= p else 0
        self.last = {key: p}
        tools = sum(m["role"] == "tool" for m in msgs)
        msg = {"role": "assistant", "content": ""}
        if tools < 2 and not (self.bad.get("no_call_at") == n):
            msg["tool_calls"] = [{"id": f"call{n}", "type": "function",
                                  "function": {"name": "bash", "arguments": f'{{"command":"cat out{tools + 1}.txt"}}'}}]
        else:
            msg["content"] = "A document. Output one. Output two."
        d = {"choices": [{"message": msg, "finish_reason": "tool_calls" if "tool_calls" in msg else "stop"}],
             "usage": {"prompt_tokens": p, "completion_tokens": 20},
             "timings": {"cache_n": cn, "prompt_n": p - cn, "prompt_ms": 1000.0, "prompt_per_second": 150.0,
                         "predicted_per_second": 5.0}}
        if self.bad.get("low_reuse_at") == n:
            d["timings"]["cache_n"] = 10
        for k in ("drop_cache_n_at", "str_cache_n_at", "drop_usage_at", "zero_pps_at", "http_at", "no_id_at"):
            if self.bad.get(k) != n:
                continue
            if k == "drop_cache_n_at": del d["timings"]["cache_n"]
            if k == "str_cache_n_at": d["timings"]["cache_n"] = str(d["timings"]["cache_n"])
            if k == "drop_usage_at": del d["usage"]
            if k == "zero_pps_at": d["timings"]["prompt_per_second"] = 0
            if k == "http_at": return 500, {"error": "x"}, 0.0
            if k == "no_id_at": del msg["tool_calls"][0]["id"]
        return 200, copy.deepcopy(d), 0.0


def run(**bad):
    vw.checks.clear(); vw.post = Fake(**bad)
    with tempfile.TemporaryDirectory() as out, redirect_stdout(io.StringIO()) as buf:
        rc = vw.main(["v0e_window.py", "cache", out, "/nonexistent", "32768", "local32k"])
        has_tx = os.path.exists(os.path.join(out, "cache-transcript.json"))
        tx = open(os.path.join(out, "cache-transcript.json")).read() if has_tx else ""
    return rc, buf.getvalue(), tx, vw.post.maxt


fails = 0
# requests: 1-3 = turns 1-3, 4 = fresh
cases = [("all-good", {}, 0), ("fresh cache_n missing", {"drop_cache_n_at": 4}, 1),
         ("fresh cache_n a string", {"str_cache_n_at": 4}, 1), ("turn 2 cache_n missing", {"drop_cache_n_at": 2}, 1),
         ("turn 3 cache_n a string", {"str_cache_n_at": 3}, 1), ("turn 2 usage missing", {"drop_usage_at": 2}, 1),
         ("fresh usage missing", {"drop_usage_at": 4}, 1), ("fresh prefill 0", {"zero_pps_at": 4}, 1),
         ("turn 3 low reuse", {"low_reuse_at": 3}, 1), ("no tool call at turn 2", {"no_call_at": 2}, 1),
         ("tool call without id", {"no_id_at": 1}, 1), ("fresh http 500", {"http_at": 4}, 1)]
for name, bad, want in cases:
    rc, text, tx, maxt = run(**bad)
    ok = rc == want
    if name == "all-good":  # the transcript holds real call/result pairs with matching ids
        ok = ok and len(re.findall(r'"role": "tool"', tx)) == 2 and '"tool_call_id": "call1"' in tx \
             and '"tool_call_id": "call2"' in tx and "turn 3 reuse after a tool result" in text \
             and maxt == [4096, 4096, 512, 512]  # D161: tool-call turns 4096, reuse-only requests 512
    print(f"{'ok  ' if ok else 'FAIL'} {name} (rc {rc}, want {want})")
    if not ok:
        fails += 1; print(text)

# D167: cache wording. "neutral" passes the same checks; the fresh request still misses (new nonce); unknown fails.
os.environ["CACHE_WORDING"] = "neutral"
rc, text, tx, maxt = run()
ok = rc == 0 and "wording: neutral" in text and '"content": "Reference ' in tx and maxt == [4096, 4096, 512, 512]
print(f"{'ok  ' if ok else 'FAIL'} cache all-good, neutral wording (rc {rc})"); fails += not ok
os.environ["CACHE_WORDING"] = "nonsense"
try:
    run(); ok = False
except SystemExit:
    ok = True
print(f"{'ok  ' if ok else 'FAIL'} cache unknown wording refused"); fails += not ok
del os.environ["CACHE_WORDING"]


class WFake(Fake):
    """wording mode: a bash call only for the neutral text (unless no_call_neutral_at), records the order"""

    def __call__(self, path, body, timeout=0):
        if path == "/tokenize":
            return super().__call__(path, body, timeout)
        self.n += 1; c = body["messages"][0]["content"]; w = "neutral" if c.startswith("Reference ") else "current"
        self.maxt.append((w, body.get("max_tokens")))
        if self.bad.get("http_at") == self.n:
            return 500, {"error": "x"}, 0.0
        call = w == "neutral" and self.bad.get("no_call_neutral_at") != self.n and self.bad.get("length_at") != self.n
        msg = {"role": "assistant", "content": "" if call else "I cannot run this."}
        if call:
            msg["tool_calls"] = [{"id": f"c{self.n}", "type": "function", "function": {"name": "bash", "arguments": '{"command":"cat out1.txt"}'}}]
        fin = "tool_calls" if call else ("length" if self.bad.get("length_at") == self.n else "stop")
        if fin == "length":
            msg["content"] = ""
        d = {"choices": [{"message": msg, "finish_reason": fin}],
             "usage": {"prompt_tokens": 8400, "completion_tokens": 900}, "timings": {"cache_n": 0, "prompt_per_second": 250.0}}
        if self.bad.get("drop_usage_at") == self.n:
            del d["usage"]
        return 200, d, 0.0


def wrun(n=8, **bad):
    vw.checks.clear(); vw.post = WFake(**bad); os.environ["WORDING_N"] = str(n)
    with tempfile.TemporaryDirectory() as out, redirect_stdout(io.StringIO()) as buf:
        rc = vw.main(["v0e_window.py", "wording", out, "/nonexistent", "32768", "local32k"])
    return rc, buf.getvalue(), vw.post.maxt


for name, kw, want, line in [
        ("wording counts", {}, 0, "FISHER: two-sided p = 0.000155"),
        ("wording outcomes by category", {"length_at": 3}, 0, "OUTCOMES neutral: call 7, stop without a call 0, "
         "length without a call 1, other finish without a call 0, incomplete 0; declining text 0"),
        ("wording declining text counted", {}, 0, "OUTCOMES current: call 0, stop without a call 8, length without a "
         "call 0, other finish without a call 0, incomplete 0; declining text 8"),
        ("wording counts a missing call", {"no_call_neutral_at": 2}, 0, "WORDING: current 0/8, neutral 7/8"),
        ("wording http 500 incomplete", {"http_at": 6}, 1, "WORDING: current 0/8, neutral 7/8"),
        ("wording usage missing incomplete", {"drop_usage_at": 1}, 1, "WORDING: current 0/8, neutral 8/8")]:
    rc, text, order = wrun(**kw)
    ok = rc == want and line in text and len(order) == 16 and [w for w, _ in order][:8] == \
        ["current", "neutral", "neutral", "current"] * 2 and {t for _, t in order} == {4096}
    print(f"{'ok  ' if ok else 'FAIL'} {name} (rc {rc}, want {want})"); fails += not ok
    if not ok:
        print(text)


class CFake:
    """the tool continuation (D167, D168): /apply-template renders role, content, tool calls and the tool list (a
    consistent server: the chat prompt is counted from the same rendering); /tokenize counts characters / 4.
    drop_tool / drop_calls: the template (and so the server) omits tool messages / assistant tool calls.
    resp: how the chat answer is damaged (no_completion, no_choices, empty_choices, no_finish, bad_finish, no_message)."""

    def __init__(self, offset=0, drop_tool=False, drop_calls=False, c2=60, trunc=False, http=200, tmpl_http=200, resp=None):
        self.offset, self.drop_tool, self.drop_calls, self.c2 = offset, drop_tool, drop_calls, c2
        self.trunc, self.http, self.tmpl_http, self.resp = trunc, http, tmpl_http, resp

    def render(self, msgs, tools):
        parts = [f"<{m['role']}>{m.get('content') or ''}" + ("" if self.drop_calls else json.dumps(m.get("tool_calls") or ""))
                 for m in msgs if not (self.drop_tool and m["role"] == "tool")]
        return json.dumps(tools) + "".join(parts) + "<assistant>"

    def __call__(self, path, body, timeout=0):
        if path == "/apply-template":
            return (200, {"prompt": self.render(body["messages"], body.get("tools"))}, 0.0) if self.tmpl_http == 200 \
                else (500, {"error": "x"}, 0.0)
        if path == "/tokenize":
            return 200, {"tokens": [0] * (len(body["content"]) // 4)}, 0.0
        if self.http != 200:
            return self.http, {"error": "x"}, 0.0
        p = len(self.render(body["messages"], body.get("tools"))) // 4 + self.offset
        d = {"choices": [{"message": {"role": "assistant", "content": "Done."}, "finish_reason": "stop"}],
             "usage": {"prompt_tokens": p, "completion_tokens": self.c2}, "timings": {"cache_n": 0}}
        if self.trunc:
            d["timings"]["truncated"] = True
        r = self.resp
        if r == "no_completion": del d["usage"]["completion_tokens"]
        if r == "no_choices": del d["choices"]
        if r == "empty_choices": d["choices"] = []
        if r == "no_finish": del d["choices"][0]["finish_reason"]
        if r == "bad_finish": d["choices"][0]["finish_reason"] = "error"
        if r == "no_message": del d["choices"][0]["message"]
        return 200, d, 0.0


import json
vw.W = 32768
code_word = "WINDOW-CHECK-862708"
msg0 = [{"role": "user", "content": "Run x. " + "w" * 120000 + f"\n\nInstruction: call the bash tool exactly once with the command: echo {code_word}"}]
call = [{"id": "Ud4d", "type": "function", "function": {"name": "bash", "arguments": json.dumps({"command": f"echo {code_word}"})}}]
m_plain = {"role": "assistant", "content": "I'll run the bash command as instructed.\n\n", "tool_calls": call}
m_echo = {"role": "assistant", "content": f"I will echo {code_word} now.", "tool_calls": call}  # the code in visible text too
p0 = len(CFake().render(msg0, vw.TOOLS)) // 4
d0 = {"usage": {"prompt_tokens": p0, "completion_tokens": 367}}  # A32-2: 367 completion tokens, most of them reasoning
for name, m0, kw, want in [
        ("continuation with a long reasoning reply passes (A32-2 shape)", m_plain, {}, True),
        ("continuation passes with the code in the visible text too", m_echo, {}, True),
        ("continuation passes with finish=length", m_plain, {"resp": None, "c2": 60}, True),
        ("continuation: server prompt differs from the serialization", m_plain, {"offset": 40}, False),
        ("continuation: tool result dropped, server consistent", m_plain, {"drop_tool": True}, False),
        ("continuation: tool result dropped, code repeated in the visible text", m_echo, {"drop_tool": True}, False),
        ("continuation: call dropped, server consistent", m_plain, {"drop_calls": True}, False),
        ("continuation: call dropped, code repeated in the visible text", m_echo, {"drop_calls": True}, False),
        ("continuation: completion_tokens missing", m_plain, {"resp": "no_completion"}, False),
        ("continuation: choices missing", m_plain, {"resp": "no_choices"}, False),
        ("continuation: choices empty", m_plain, {"resp": "empty_choices"}, False),
        ("continuation: finish_reason missing", m_plain, {"resp": "no_finish"}, False),
        ("continuation: finish_reason invalid", m_plain, {"resp": "bad_finish"}, False),
        ("continuation: message missing", m_plain, {"resp": "no_message"}, False),
        ("continuation: over the window", m_plain, {"c2": 32768}, False),
        ("continuation: truncated", m_plain, {"trunc": True}, False),
        ("continuation: http 500", m_plain, {"http": 500}, False),
        ("continuation: apply-template unavailable", m_plain, {"tmpl_http": 500}, False)]:
    f = CFake(**kw)
    if name.endswith("finish=length"):
        orig = f.__call__
        def f(path, body, timeout=0, orig=orig):
            c, d, t = orig(path, body, timeout)
            if path == "/v1/chat/completions":
                d["choices"][0]["finish_reason"] = "length"
            return c, d, t
    vw.checks.clear(); vw.post = f
    with redirect_stdout(io.StringIO()) as buf:
        vw.continuation(list(msg0), p0, d0, m0, call, code_word)
    ok = vw.checks == [want]
    if name.startswith("continuation with"):  # the pre-D167 bound would have failed this valid continuation
        p2 = int(re.search(r"prompt=(\d+) \(serialized", buf.getvalue()).group(1))
        ok = ok and p2 < p0 + 367 - 64
    print(f"{'ok  ' if ok else 'FAIL'} {name}"); fails += not ok
    if not ok or os.environ.get("VERBOSE"):  # VERBOSE=1: the check's detail line for every case
        print("     " + "".join(l for l in buf.getvalue().splitlines(True) if "tool continuation" in l).strip())
print(f"failures: {fails}"); sys.exit(fails)
