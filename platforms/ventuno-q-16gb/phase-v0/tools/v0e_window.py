#!/usr/bin/env python3
"""v0e_window.py <window|cache> <out dir> <server.log> <window> <pi model id>   (V0e steps 2 and 3, D112)

window: RUNBOOK V0e step 2 at <window>, against the running server ($URL, default http://127.0.0.1:8080).
  - agreement: the model metadata (n_ctx_train in server.log), llama-server's effective per-sequence context
    (n_ctx_seq in server.log, n_ctx in /props) and pi's advertised window (contextWindow of <pi model id> in
    ~/.pi/agent/models.json) must agree: n_ctx_seq == /props n_ctx == pi window <= n_ctx_train;
  - near-limit prompt: one request whose prompt is >= 95 % of the window and leaves >= 1024 tokens for the reply,
    offering a bash tool and asking for one call with a code; up to 2 attempts (a new nonce each; the second only if
    the model did not make the call). PASS: HTTP 200, prompt in range, no truncation, a bash call with the code;
  - tool continuation: the call and its tool result appended; PASS: HTTP 200, the new prompt is longer than the
    first prompt plus its reply minus 64, prompt + reply <= window, no truncation. The finish reason is recorded.
  (Compaction is checked through real pi: v0e_compact.sh.)
cache: RUNBOOK V0e step 3, cached multi-turn reuse reported separately from fresh-prefix speed: a ~8K-token transcript,
  then two turns each appending a tool output (~2K tokens); then the same final prompt with a new nonce (fresh). PASS:
  the server reports timings.cache_n, and turns 2 and 3 reuse >= 90 % of the previous turn's prompt.
Raw responses go to <out dir>/<mode>.jsonl; checks to stdout. Exit 0 only if every check passed."""
import json, os, random, re, sys, time, urllib.error, urllib.request, uuid

sys.path.insert(0, os.path.expanduser("~/v0/measure/suite/tools"))
from speed_probe import corpus  # the frozen corpus (measurement commit 7badb21)

URL = os.environ.get("URL", "http://127.0.0.1:8080")
TOOLS = [{"type": "function", "function": {"name": "bash", "description": "Run a shell command",
          "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}}]
mode, out, slog, W, pim = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
RAW = open(os.path.join(out, f"{mode}.jsonl"), "a")
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
    u, t = d.get("usage", {}), d.get("timings", {})
    return (f"prompt={u.get('prompt_tokens')} completion={u.get('completion_tokens')} cache_n={t.get('cache_n')} "
            f"prompt_n={t.get('prompt_n')} prefill={t.get('prompt_per_second', 0):.1f} decode={t.get('predicted_per_second', 0):.2f}")


def text_of(tokens, cpt=3.2):
    """corpus text of about <tokens> tokens (calibrated with /tokenize)"""
    chars = int(tokens * cpt)
    for _ in range(4):
        t = corpus(chars); n = ntok(t)
        if abs(n - tokens) <= 64:
            return t
        chars = int(chars * tokens / max(n, 1))
    return corpus(chars)


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
    c0 = d.get("usage", {}).get("completion_tokens") or 0
    msg += [{"role": "assistant", "content": m.get("content") or "", "tool_calls": calls[:1]},
            {"role": "tool", "tool_call_id": calls[0].get("id", ""), "content": code_word + "\n"}]
    code2, d2, dt2 = chat(msg, max(64, min(1024, W - p - c0 - 128)), TOOLS)
    p2 = d2.get("usage", {}).get("prompt_tokens") or 0; c2 = d2.get("usage", {}).get("completion_tokens") or 0
    fr2 = (d2.get("choices") or [{}])[0].get("finish_reason"); tr2 = d2.get("timings", {}).get("truncated") or d2.get("truncated")
    print(f"continuation: http={code2} {summary(d2)} finish={fr2} {dt2:.0f}s")
    check("tool continuation", code2 == 200 and p2 >= p + c0 - 64 and p2 + c2 <= W and not tr2,
          f"http={code2} prompt={p2} reply={c2} total={p2 + c2} of {W}, finish={fr2}, cache_n={d2.get('timings', {}).get('cache_n')}")


def cache():
    nonce = uuid.uuid4()
    msg = [{"role": "user", "content": f"Run {nonce}. Here is a project document.\n\n" + text_of(8000)
            + "\n\nIn one sentence, what is this document about?"}]
    prev = None
    for turn in (1, 2, 3):
        code, d, dt = chat(msg, 256)
        p = d.get("usage", {}).get("prompt_tokens") or 0; t = d.get("timings", {})
        print(f"turn {turn}: http={code} {summary(d)} {dt:.0f}s")
        if turn > 1:
            cn = t.get("cache_n")
            check(f"turn {turn} reuse", code == 200 and isinstance(cn, int) and cn >= 0.9 * prev,
                  f"cache_n={cn} of previous prompt {prev} ({(cn or 0) / max(prev, 1):.1%}), new tokens prompt_n={t.get('prompt_n')}, "
                  f"effective prefill {p / max(t.get('prompt_ms', 1) / 1000, 1e-9):.0f} tok/s over the whole prompt")
        elif code != 200:
            check("turn 1", False, f"http={code}"); return
        prev = p
        reply = (d.get("choices") or [{}])[0].get("message", {}).get("content") or ""
        msg += [{"role": "assistant", "content": reply},
                {"role": "user", "content": f"Tool output {turn}:\n" + text_of(2000) + "\n\nSummarize this tool output in one line."}]
    msg[0]["content"] = msg[0]["content"].replace(str(nonce), str(uuid.uuid4()))
    code, d, dt = chat(msg[:-2], 256)  # the turn-3 prompt, with a new nonce at its start
    print(f"fresh (same final prompt, new nonce): http={code} {summary(d)} {dt:.0f}s")
    check("fresh prefix reported separately", code == 200 and (d.get("timings", {}).get("cache_n") or 0) < 64,
          f"cache_n={d.get('timings', {}).get('cache_n')} prefill={d.get('timings', {}).get('prompt_per_second', 0):.1f} tok/s")


{"window": window, "cache": cache}[mode]()
print(f"RESULT {mode}: {'PASS' if checks and all(checks) else 'FAIL'} ({sum(checks)}/{len(checks)} checks)")
sys.exit(0 if checks and all(checks) else 1)
