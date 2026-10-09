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
        self.bad, self.n, self.last = bad, 0, {}

    def __call__(self, path, body, timeout=0):
        if path == "/tokenize":
            return 200, {"tokens": [0] * int(len(body["content"]) / 3.2)}, 0.0
        self.n += 1; n = self.n; msgs = body["messages"]
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
    return rc, buf.getvalue(), tx


fails = 0
# requests: 1-3 = turns 1-3, 4 = fresh
cases = [("all-good", {}, 0), ("fresh cache_n missing", {"drop_cache_n_at": 4}, 1),
         ("fresh cache_n a string", {"str_cache_n_at": 4}, 1), ("turn 2 cache_n missing", {"drop_cache_n_at": 2}, 1),
         ("turn 3 cache_n a string", {"str_cache_n_at": 3}, 1), ("turn 2 usage missing", {"drop_usage_at": 2}, 1),
         ("fresh usage missing", {"drop_usage_at": 4}, 1), ("fresh prefill 0", {"zero_pps_at": 4}, 1),
         ("turn 3 low reuse", {"low_reuse_at": 3}, 1), ("no tool call at turn 2", {"no_call_at": 2}, 1),
         ("tool call without id", {"no_id_at": 1}, 1), ("fresh http 500", {"http_at": 4}, 1)]
for name, bad, want in cases:
    rc, text, tx = run(**bad)
    ok = rc == want
    if name == "all-good":  # the transcript holds real call/result pairs with matching ids
        ok = ok and len(re.findall(r'"role": "tool"', tx)) == 2 and '"tool_call_id": "call1"' in tx \
             and '"tool_call_id": "call2"' in tx and "turn 3 reuse after a tool result" in text
    print(f"{'ok  ' if ok else 'FAIL'} {name} (rc {rc}, want {want})")
    if not ok:
        fails += 1; print(text)
print(f"failures: {fails}"); sys.exit(fails)
