#!/usr/bin/env python3
"""v0e_window.py <window|cache> <out dir> <server.log> <window> <pi model id>   (V0e steps 2 and 3, D112)

window: RUNBOOK V0e step 2 at <window>, against the running server ($URL, default http://127.0.0.1:8080).
  - agreement: the model metadata (n_ctx_train in server.log), llama-server's effective per-sequence context
    (n_ctx_seq in server.log, n_ctx in /props) and pi's advertised window (contextWindow of <pi model id> in
    ~/.pi/agent/models.json) must agree: n_ctx_seq == /props n_ctx == pi window <= n_ctx_train;
  - near-limit prompt: one request whose prompt is >= 95 % of the window and leaves >= 1024 tokens for the reply,
    offering a bash tool and asking for one call with a code; up to 2 attempts (a new nonce each; the second only if
    the model did not make the call). PASS: HTTP 200, prompt in range, no truncation, a bash call with the code;
  - tool continuation: the call and its tool result appended; PASS (D167): HTTP 200, the server's prompt_tokens equal
    (within 4) the token count of the server's own serialization of the continued conversation (/apply-template with
    the tools, then /tokenize with special tokens, as the chat endpoint does), that serialization carries the call and
    the result (the code word at least twice more than in the first prompt's), the prompt grew, prompt + reply <=
    window, no truncation. The finish reason is recorded. (Before D167 the bound was first prompt + completion - 64,
    which counted reasoning tokens the template does not send back: A32-2, D165/D166.)
  (Compaction is checked through real pi: v0e_compact.sh.)
cache: RUNBOOK V0e step 3, cached multi-turn reuse with real tool-result history, reported separately from fresh-prefix
  speed (D117): turn 1 is a ~8K-token document plus an instruction to run two bash commands one at a time; the model's own
  bash calls are kept as assistant tool_calls and each gets a role "tool" result (~2K tokens) with the matching
  tool_call_id; turns 2 and 3 continue from those results. Then the turn-3 prompt with a new nonce at its start (fresh).
  Fail closed: every turn needs HTTP 200 and a positive integer usage.prompt_tokens; turns 1 and 2 need a bash call with a
  call id (else FAIL, not retried); turns 2 and 3 need an integer timings.cache_n >= 90 % of the previous prompt; the
  fresh request needs an integer cache_n in [0, 64), a prompt within 64 tokens of turn 3's, and a positive prefill rate.
  An absent or malformed counter is a FAIL. The final transcript goes to <out dir>/cache-transcript.json.
  Wording (D167): $CACHE_WORDING selects turn 1's text, "current" (default, unchanged since D112) or "neutral" (the
  nonce as a reference line, the task before the document, the document marked as reference material).
wording (D167, A32-3 stage S0): turn 1 of the cache item only, $WORDING_N times per wording (default 8), in the order
  current, neutral, neutral, current, ... (ABBA, against drift), each with a new nonce, the same document and the cache
  item's budget (CACHE_TOOL_MAX). Records per try whether a bash call with an id came back. Complete only if every
  request returned HTTP 200 with a positive integer usage.prompt_tokens and a finish reason; the counts are a result,
  not a check. Last lines: "WORDING: current k/N, neutral m/N" and the RESULT line.
Raw responses go to <out dir>/<mode>.jsonl; checks to stdout. Exit 0 only if every check passed."""
import json, os, random, re, sys, time, urllib.error, urllib.request, uuid

sys.path.insert(0, os.path.expanduser("~/v0/measure/suite/tools"))
from speed_probe import corpus  # the frozen corpus (measurement commit 7badb21)

URL = os.environ.get("URL", "http://127.0.0.1:8080")
TOOLS = [{"type": "function", "function": {"name": "bash", "description": "Run a shell command",
          "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}}]
mode = out = slog = W = pim = RAW = None
checks = []


def check(name, ok, detail):
    checks.append(ok); print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}", flush=True)


def post(path, body, timeout=2400):
    req = urllib.request.Request(URL + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            code, data = r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        code, data = e.code, {"error": e.read().decode(errors="replace")[:2000]}
    dt = time.monotonic() - t0
    RAW.write(json.dumps({"path": path, "code": code, "seconds": round(dt, 1), "response": data}) + "\n"); RAW.flush()
    return code, data, dt


def chat(messages, max_tokens, tools=None):
    body = {"messages": messages, "max_tokens": max_tokens}
    if tools:
        body["tools"] = tools
    return post("/v1/chat/completions", body)


def ntok(text):
    return len(post("/tokenize", {"content": text}, 120)[1].get("tokens", []))


def summary(d):
    u, t = d.get("usage") or {}, d.get("timings") or {}
    f = lambda v, n: f"{v:.{n}f}" if isinstance(v, (int, float)) else repr(v)
    return (f"prompt={u.get('prompt_tokens')!r} completion={u.get('completion_tokens')!r} cache_n={t.get('cache_n')!r} "
            f"prompt_n={t.get('prompt_n')!r} prefill={f(t.get('prompt_per_second'), 1)} decode={f(t.get('predicted_per_second'), 2)}")


def text_of(tokens, cpt=3.2):
    """corpus text of about <tokens> tokens (calibrated with /tokenize)"""
    chars = int(tokens * cpt)
    for _ in range(4):
        t = corpus(chars); n = ntok(t)
        if abs(n - tokens) <= 64:
            return t
        chars = int(chars * tokens / max(n, 1))
    return corpus(chars)


def apply_template(messages, tools=None):
    """the server's own serialization of a chat request (llama-server /apply-template), or None"""
    body = {"messages": messages}
    if tools:
        body["tools"] = tools
    code, d, _ = post("/apply-template", body, 300)
    return d.get("prompt") if code == 200 and isinstance(d.get("prompt"), str) else None


def ntok_special(text):
    """token count of a serialized prompt as the chat endpoint tokenizes it (special tokens added and parsed)"""
    code, d, _ = post("/tokenize", {"content": text, "add_special": True, "parse_special": True}, 300)
    t = d.get("tokens") if code == 200 else None
    return len(t) if isinstance(t, list) else None


def continuation(msg, p, d, m, calls, code_word):
    """D167: the tool continuation, checked against the server's serialization of what is actually sent"""
    c0 = d.get("usage", {}).get("completion_tokens") or 0
    first = apply_template(msg, TOOLS)
    msg = msg + [{"role": "assistant", "content": m.get("content") or "", "tool_calls": calls[:1]},
                 {"role": "tool", "tool_call_id": calls[0].get("id", ""), "content": code_word + "\n"}]
    code2, d2, dt2 = chat(msg, max(64, min(1024, W - p - c0 - 128)), TOOLS)
    p2 = d2.get("usage", {}).get("prompt_tokens") or 0; c2 = d2.get("usage", {}).get("completion_tokens") or 0
    fr2 = (d2.get("choices") or [{}])[0].get("finish_reason"); tr2 = d2.get("timings", {}).get("truncated") or d2.get("truncated")
    print(f"continuation: http={code2} {summary(d2)} finish={fr2} {dt2:.0f}s")
    ser = apply_template(msg, TOOLS); e2 = ntok_special(ser) if ser is not None else None
    carried = ser is not None and first is not None and ser.count(code_word) >= first.count(code_word) + 2
    check("tool continuation", code2 == 200 and e2 is not None and abs(p2 - e2) <= 4 and carried and p2 > p
          and p2 + c2 <= W and not tr2,
          f"http={code2} prompt={p2} (serialized continuation {e2}; first prompt {p}, its reply {c0} incl. reasoning) "
          f"call and result in the serialization: {'yes' if carried else 'no'}, reply={c2} total={p2 + c2} of {W}, "
          f"finish={fr2}, cache_n={d2.get('timings', {}).get('cache_n')}")


def window():
    log = open(slog, errors="replace").read()
    train = re.search(r"n_ctx_train\s*=\s*(\d+)", log); seq = re.search(r"n_ctx_seq \((\d+)\)", log)
    seq = seq or re.search(r"llama_context: n_ctx\s*=\s*(\d+)", log)
    props = json.load(urllib.request.urlopen(URL + "/props", timeout=60))
    pn = props.get("default_generation_settings", {}).get("n_ctx")
    models = json.load(open(os.path.expanduser("~/.pi/agent/models.json")))
    piw = next((m["contextWindow"] for p in models["providers"].values() for m in p["models"] if m["id"] == pim), None)
    train, seq = (int(train.group(1)) if train else None), (int(seq.group(1)) if seq else None)
    check("windows agree", None not in (train, seq, pn, piw) and seq == pn == piw == W and W <= train,
          f"n_ctx_train={train} n_ctx_seq={seq} /props n_ctx={pn} pi {pim}={piw} intended={W}")
    # overhead of the template + tool declaration, measured with a tiny request
    code, d, _ = chat([{"role": "user", "content": "Say OK."}], 1, TOOLS)
    over = d.get("usage", {}).get("prompt_tokens", 400) - ntok("Say OK.")
    target = W - 1024 - 256 - over  # reply room 1024, margin 256 for the instruction lines
    body_text = text_of(target)
    for attempt in (1, 2):
        code_word = f"WINDOW-CHECK-{random.randint(100000, 999999)}"
        msg = [{"role": "user", "content": f"Run {uuid.uuid4()}. Read the document below; an instruction follows it.\n\n"
                + body_text + f"\n\nInstruction: call the bash tool exactly once with the command: echo {code_word}"}]
        code, d, dt = chat(msg, 1024, TOOLS)
        p = d.get("usage", {}).get("prompt_tokens") or 0
        m = (d.get("choices") or [{}])[0].get("message", {}); fr = (d.get("choices") or [{}])[0].get("finish_reason")
        calls = [c for c in (m.get("tool_calls") or []) if c.get("function", {}).get("name") == "bash"]
        made = any(code_word in c["function"].get("arguments", "") for c in calls)
        print(f"near-limit attempt {attempt}: http={code} {summary(d)} finish={fr} call={'yes' if made else 'no'} {dt:.0f}s")
        if code != 200 or made:
            break
    trunc = d.get("timings", {}).get("truncated") or d.get("truncated")
    check("near-limit prompt", code == 200 and 0.95 * W <= p <= W - 1024 and not trunc,
          f"http={code} prompt={p} of {W} ({p / W:.1%}), reply room {W - p}, truncated={bool(trunc)}")
    check("near-limit tool call", made, f"finish={fr}, bash call with the code: {'yes' if made else 'no'} (attempt {attempt})")
    if not made:
        check("tool continuation", False, "not run: no tool call to continue"); return
    continuation(msg, p, d, m, calls, code_word)


def counters(d):
    """(prompt_tokens, cache_n, prompt_per_second) when present and well-formed, else None for that field"""
    p = (d.get("usage") or {}).get("prompt_tokens"); t = d.get("timings") or {}
    cn, pps = t.get("cache_n"), t.get("prompt_per_second")
    ok_int = lambda v, lo: isinstance(v, int) and not isinstance(v, bool) and v >= lo
    return (p if ok_int(p, 1) else None, cn if ok_int(cn, 0) else None,
            pps if isinstance(pps, (int, float)) and not isinstance(pps, bool) and pps > 0 else None)


# D161 (v0e-plan-A32-2.txt): the two turns that must produce a tool call get 4096 completion tokens (512 before; A32
# attempt 1 spent all 512 on reasoning, D159). Turn 3 and the fresh request only measure prompt reuse: 512 as before.
CACHE_TOOL_MAX = 4096


def turn1(nonce, body, wording):
    """the cache item's first user message (D167: "neutral" next to the unchanged "current")"""
    if wording == "current":
        return (f"Run {nonce}. Here is a project document.\n\n" + body
                + "\n\nNow inspect two log files, one at a time: first call the bash tool with the command cat out1.txt; after "
                "you see its output, call it with the command cat out2.txt. After both outputs, reply with one sentence about "
                "the document and one line about each output.")
    if wording == "neutral":
        return (f"Reference {nonce}.\n\nTask: inspect two log files with the bash tool, one at a time. First call the bash "
                "tool with the command cat out1.txt; after you see its output, call it with the command cat out2.txt. After "
                "both outputs, reply with one sentence about the document below and one line about each output.\n\n"
                "Document (reference material for that sentence only):\n\n" + body
                + "\n\nStart with the first step: call the bash tool with the command cat out1.txt.")
    raise SystemExit(f"unknown wording {wording!r}")


def cache():
    nonce = uuid.uuid4(); wording = os.environ.get("CACHE_WORDING", "current")
    print(f"wording: {wording}")
    msg = [{"role": "user", "content": turn1(nonce, text_of(8000), wording)}]
    prev = final = None
    for turn in (1, 2, 3):
        sent = [dict(m) for m in msg]
        code, d, dt = chat(msg, CACHE_TOOL_MAX if turn < 3 else 512, TOOLS)
        p, cn, _ = counters(d)
        print(f"turn {turn}: http={code} {summary(d)} {dt:.0f}s")
        if code != 200 or p is None:
            check(f"turn {turn}", False, f"http={code} prompt_tokens={(d.get('usage') or {}).get('prompt_tokens')!r}"); return
        if turn > 1:
            t = d.get("timings") or {}
            check(f"turn {turn} reuse after a tool result", cn is not None and cn >= 0.9 * prev,
                  f"cache_n={t.get('cache_n')!r} of previous prompt {prev} ({(cn or 0) / prev:.1%}), new tokens "
                  f"prompt_n={t.get('prompt_n')}, effective prefill {p / max((t.get('prompt_ms') or 1) / 1000, 1e-9):.0f} "
                  "tok/s over the whole prompt")
        prev, final = p, sent
        if turn == 3:
            break
        m = (d.get("choices") or [{}])[0].get("message") or {}
        calls = [c for c in (m.get("tool_calls") or []) if (c.get("function") or {}).get("name") == "bash" and c.get("id")]
        cmd = (calls[0]["function"].get("arguments") or "") if calls else ""
        check(f"turn {turn} tool call", bool(calls), f"bash call with an id: {'yes' if calls else 'no'}"
              + (f", arguments {cmd[:80]!r} (asked for cat out{turn}.txt)" if calls else ""))
        if not calls:
            return
        msg += [{"role": "assistant", "content": m.get("content") or "", "tool_calls": calls[:1]},
                {"role": "tool", "tool_call_id": calls[0]["id"], "content": f"out{turn}.txt:\n" + text_of(2000)}]
    json.dump(final, open(os.path.join(out, "cache-transcript.json"), "w"), indent=1)
    p3 = prev
    final[0]["content"] = final[0]["content"].replace(str(nonce), str(uuid.uuid4()))
    code, d, dt = chat(final, 512, TOOLS)  # the turn-3 prompt, with a new nonce at its start
    p, cn, pps = counters(d)
    print(f"fresh (same final prompt, new nonce): http={code} {summary(d)} {dt:.0f}s")
    t = d.get("timings") or {}
    check("fresh prefix reported separately",
          code == 200 and p is not None and abs(p - p3) <= 64 and cn is not None and cn < 64 and pps is not None,
          f"http={code} prompt={p} (turn 3: {p3}) cache_n={t.get('cache_n')!r} prefill={t.get('prompt_per_second')!r} tok/s")


def wording():
    n = int(os.environ.get("WORDING_N", "8")); body = text_of(8000)
    order = [("current", "neutral", "neutral", "current")[i % 4] for i in range(2 * n)]
    calls_by = {"current": 0, "neutral": 0}; complete = True
    for i, w in enumerate(order, 1):
        code, d, dt = chat([{"role": "user", "content": turn1(uuid.uuid4(), body, w)}], CACHE_TOOL_MAX, TOOLS)
        p, _, _ = counters(d); ch = (d.get("choices") or [{}])[0]; fr = ch.get("finish_reason")
        m = ch.get("message") or {}
        calls = [c for c in (m.get("tool_calls") or []) if (c.get("function") or {}).get("name") == "bash" and c.get("id")]
        ok = code == 200 and p is not None and isinstance(fr, str)
        complete = complete and ok; calls_by[w] += bool(calls)
        print(f"try {i} {w}: http={code} {summary(d)} finish={fr} bash call with an id: {'yes' if calls else 'no'}"
              + (f" {(calls[0]['function'].get('arguments') or '')[:60]!r}" if calls else "") + f" {dt:.0f}s")
    check(f"{2 * n} complete requests", complete, "every try HTTP 200 with prompt_tokens and a finish reason")
    print(f"FISHER: two-sided p = {fisher(calls_by['current'], n, calls_by['neutral'], n):.3g} (reported, not a check)")
    print(f"WORDING: current {calls_by['current']}/{n}, neutral {calls_by['neutral']}/{n}")


def fisher(a, n1, b, n2):
    """two-sided Fisher exact test of a/n1 vs b/n2 (sum of tables no more likely than the observed one)"""
    from math import comb
    k, tot = a + b, comb(n1 + n2, a + b)
    pr = lambda x: comb(n1, x) * comb(n2, k - x) / tot
    p0 = pr(a)
    return min(1.0, sum(pr(x) for x in range(max(0, k - n2), min(k, n1) + 1) if pr(x) <= p0 * (1 + 1e-9)))


def main(argv):
    global mode, out, slog, W, pim, RAW
    mode, out, slog, W, pim = argv[1], argv[2], argv[3], int(argv[4]), argv[5]
    RAW = open(os.path.join(out, f"{mode}.jsonl"), "a")
    {"window": window, "cache": cache, "wording": wording}[mode]()
    print(f"RESULT {mode}: {'PASS' if checks and all(checks) else 'FAIL'} ({sum(checks)}/{len(checks)} checks)")
    return 0 if checks and all(checks) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
