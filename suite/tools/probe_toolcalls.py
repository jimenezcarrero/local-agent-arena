#!/usr/bin/env python3
"""probe_toolcalls.py — can this llama-server's parser read the model's tool calls?

  probe_toolcalls.py probe <label> <evidence.txt> [--url URL] [--n 10] [--model ID] [--no-props] [--stream]
      N requests offering one bash tool, thinking left at the template default.
      Appends to <evidence.txt>: server build, model, the chat template's sha256,
      the sha256 of a fixed conversation rendered by /apply-template, the
      effective sampling, and one classified line per probe; the raw responses
      go to <evidence>.<label>.jsonl. Exit 0 only if every probe passed.

  probe_toolcalls.py agentic <label> <evidence.txt> [--url URL] [--n 3] [--model ID] [--stream]
      Multi-turn loops, the failure class a one-shot probe can't see: a tool
      call; after a tool result, another call; after a deliberate validation
      error, correction turns until a valid edit_line call with nested
      arguments ({"target": {"path", "line"}, "text"}). Every call is checked
      against its tool's declared schema. Any malformed turn fails at once; a
      well-formed loop that never edits, answers in prose, or exhausts its
      4096-token generation budget before a parsed call is inconclusive and
      replaced (at most
      N + 2 attempts). Exit 0 only with N passing loops and no stack failure.

  probe_toolcalls.py workaround <out.jinja> [--url URL]
      Writes the running server's chat template with the llama.cpp #29319
      workaround applied: the literal '<function=' split so template detection
      stops choosing the Qwen3-Coder parser; the rendered prompt must not change
      (compare the render sha256 of the two probe runs).

--stream sends the same requests streamed (stream=true), as pi does, and
assembles the reply the way pi's OpenAI-compatible client does: each delta finds
its call by index, else by id, both registered as aliases (so a call that gets
its index late stays one call); the first non-empty id and name are kept and
argument fragments concatenated. A stream that can't be assembled into well-formed calls
is classed stream-defect (a stack failure): a call without an id or a name, an
id that changes, deltas after the finish_reason, or no finish_reason at all.
The assembled reply is then classified exactly like a non-streamed one.

Any OpenAI-compatible server works: --model sends a model id (servers such as
GenieX require one), and --no-props skips /props and /apply-template on servers
that lack them (the evidence then says so, and has no template or render hash).

Classes: pass (finish=tool_calls, known tool, JSON arguments, no leaked tags);
sig-29319 (finish=length and a leaked '</parameter>' in the arguments or text:
the known parser mismatch); leaked-call (no parsed call, but tool-call markup
in the answer, or call tags in the reasoning: the serving layer missed it; a
JSON sketch in the reasoning is planning, not a missed call); budget
(generation budget exhausted before a parsed tool call, with no tool markup
anywhere in the output); no-call (plain prose, no call);
server-error; other (including arguments that aren't an object with a
non-empty string "command"). If /props or /apply-template fails, the evidence
file still gets a header-error block and the exit code is 2.
"""
import hashlib, json, re, sys, urllib.request

TOOLS = [{"type": "function", "function": {"name": "bash", "description": "Run a shell command",
          "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}}]
PROBE = [{"role": "system", "content": "You are a coding agent. Use the bash tool to act."},
         {"role": "user", "content": "List the files in the current directory."}]
RENDER = PROBE + [
    {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "type": "function",
     "function": {"name": "bash", "arguments": "{\"command\": \"ls -la\"}"}}]},
    {"role": "tool", "tool_call_id": "c1", "content": "a.py\nb.py"}]


STREAM = False   # set by --stream


def stream_call(url, body, timeout=900):
    """(reply shaped like a non-streamed completion, [stream defects])"""
    body = dict(body, stream=True, stream_options={"include_usage": True})
    req = urllib.request.Request(url + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    content, reasoning, blocks, by_index, by_id, finish, usage, issues = [], [], [], {}, {}, None, {}, []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            ev = json.loads(data)
            usage = ev.get("usage") or usage
            for ch in ev.get("choices") or []:
                d = ch.get("delta") or {}
                if finish is not None and (d.get("content") or d.get("tool_calls")):
                    issues.append("delta after the finish_reason")
                if d.get("content"):
                    content.append(d["content"])
                if d.get("reasoning_content"):
                    reasoning.append(d["reasoning_content"])
                for tc in d.get("tool_calls") or []:
                    # pi 0.80.10 ensureToolCallBlock: look up by index, else by id;
                    # create a block if neither matches; register both as aliases
                    idx = tc.get("index") if isinstance(tc.get("index"), int) else None
                    tid = tc.get("id") or ""
                    f = tc.get("function") or {}
                    c = by_index.get(idx) if idx is not None else None
                    if c is None and tid:
                        c = by_id.get(tid)
                    if c is None:
                        c = {"id": tid, "name": f.get("name") or "", "arguments": ""}
                        blocks.append(c)
                    if idx is not None:
                        by_index[idx] = c
                    if tid:
                        if c["id"] and c["id"] != tid:
                            issues.append(f"call {blocks.index(c)}: id changed mid-stream")
                        c["id"] = c["id"] or tid
                        by_id[tid] = c
                    c["name"] = c["name"] or f.get("name") or ""
                    c["arguments"] += f.get("arguments") or ""
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
    if finish is None:
        issues.append("the stream ended without a finish_reason")
    tool_calls = []
    for k, c in enumerate(blocks):
        if not c["id"]:
            issues.append(f"call {k}: no id")
        if not c["name"]:
            issues.append(f"call {k}: no name")
        tool_calls.append({"id": c["id"], "type": "function",
                           "function": {"name": c["name"], "arguments": c["arguments"]}})
    msg = {"role": "assistant", "content": "".join(content) or None,
           "reasoning_content": "".join(reasoning) or None, "tool_calls": tool_calls}
    return {"choices": [{"finish_reason": finish, "message": msg}], "usage": usage}, issues


def complete(url, body):
    """(reply, [stream defects]) over the transport chosen by --stream"""
    if STREAM:
        return stream_call(url, body)
    return call(url, "/v1/chat/completions", body), []


def call(url, path, body=None, timeout=900):
    req = urllib.request.Request(url + path, json.dumps(body).encode() if body is not None else None,
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


def valid(obj, schema):
    """Arguments against a declared JSON schema (object/string/integer; required strings non-empty)."""
    t = schema.get("type")
    if t == "object":
        if not isinstance(obj, dict):
            return False
        props = schema.get("properties", {})
        for k in schema.get("required", []):
            if k not in obj:
                return False
        return all(valid(obj[k], props[k]) for k in obj if k in props)
    if t == "string":
        return isinstance(obj, str) and bool(obj.strip())
    if t == "integer":
        return isinstance(obj, int) and not isinstance(obj, bool)
    return True


def classify(r, tools=TOOLS, want=None):
    """want: the tool name a turn must call (None = any declared tool)."""
    schemas = {t["function"]["name"]: t["function"]["parameters"] for t in tools}
    c = r["choices"][0]
    msg, fin = c["message"], c["finish_reason"]
    calls = msg.get("tool_calls") or []
    content, reasoning = msg.get("content") or "", msg.get("reasoning_content") or ""
    blob = content + reasoning + "".join(t["function"].get("arguments") or "" for t in calls)
    if fin == "length" and "</parameter>" in blob:
        return "sig-29319"
    if fin == "tool_calls" and calls:
        for t in calls:
            name, a = t["function"]["name"], t["function"].get("arguments") or ""
            if name not in schemas or (want and name != want) or "</" in a or "<tool_call>" in a:
                return "other"
            try:
                obj = json.loads(a)
            except (ValueError, TypeError):
                return "other"
            if not valid(obj, schemas[name]):
                return "other"
        return "pass"
    # In the answer, any call syntax (tags or JSON arguments) is a call the parser missed. In the
    # reasoning, only real call tags count: models sketch JSON calls while planning (seen with
    # Granite 4.2), and a sketch is not a missed call.
    if not calls and (re.search(r'<\|?tool_call|<function=|"arguments"\s*:', content)
                      or re.search(r'<\|?tool_call|<function=', reasoning)):
        return "leaked-call"
    if not calls and fin == "length":
        return "budget"
    if not calls and fin == "stop":
        return "no-call"
    return "other"


def header(url, no_props):
    if no_props:
        return {}, None, None, {}
    p = call(url, "/props")
    tmpl = p.get("chat_template") or ""
    rendered = call(url, "/apply-template", {"messages": RENDER, "tools": TOOLS}).get("prompt", "")
    s = p.get("default_generation_settings", {}).get("params", {})
    samp = {k: s.get(k) for k in ("temperature", "top_k", "top_p", "min_p", "presence_penalty")}
    return p, tmpl, rendered, samp


def probe(label, out, url, n, model=None, no_props=False):
    try:
        p, tmpl, rendered, samp = header(url, no_props)
    except Exception as e:  # the gate's evidence is written whatever fails
        err = f"{type(e).__name__}: {e}"
        with open(out, "a") as f:
            f.write(f"## {label}\nheader error (/props or /apply-template): {err}\n"
                    f"RESULT {label}: header-error, no probes run\n\n")
        print(f"RESULT {label}: header-error ({err})")
        return 2
    lines = [f"## {label}",
             f"build: {p.get('build_info', 'unknown')}",
             f"model: {p.get('model_path', 'unknown')}",
             f"chat_template sha256: {sha(tmpl) if tmpl is not None else 'n/a (--no-props)'}",
             f"rendered fixed conversation sha256: {sha(rendered) if rendered is not None else 'n/a (--no-props)'}",
             f"sampling: {json.dumps(samp) if samp else 'n/a (--no-props)'}",
             f"model id sent: {model or 'none'}",
             f"probes: {n}, max_tokens 400, thinking unset, {'streamed' if STREAM else 'non-streamed'}"]
    counts = {}
    with open(f"{out}.{label}.jsonl", "a") as raw:
        for i in range(1, n + 1):
            try:
                body = {"messages": PROBE, "tools": TOOLS, "max_tokens": 400}
                if model:
                    body["model"] = model
                r, issues = complete(url, body)
                cls = "stream-defect" if issues else classify(r)
                c = r["choices"][0]
                args = [t["function"].get("arguments") for t in c["message"].get("tool_calls") or []]
                detail = (f"finish={c['finish_reason']} tokens={(r.get('usage') or {}).get('completion_tokens', '?')} "
                          f"args={json.dumps(args)[:120]}" + (f" DEFECTS: {'; '.join(issues)}" if issues else ""))
                raw.write(json.dumps({"label": label, "i": i, "class": cls, "response": r}) + "\n")
            except Exception as e:  # a failed request is a probe outcome, recorded as such
                cls, detail = "server-error", f"{type(e).__name__}: {e}"
                raw.write(json.dumps({"label": label, "i": i, "class": cls, "error": detail}) + "\n")
            counts[cls] = counts.get(cls, 0) + 1
            lines.append(f"probe {i:2d}: {cls:<12} {detail}")
            print(lines[-1], flush=True)
    summary = " ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    lines.append(f"RESULT {label}: pass {counts.get('pass', 0)}/{n} ({summary})")
    with open(out, "a") as f:
        f.write("\n".join(lines) + "\n\n")
    print(lines[-1])
    return 0 if counts.get("pass", 0) == n else 1


AG_TOOLS = TOOLS + [{"type": "function", "function": {
    "name": "edit_line", "description": "Replace one line of a file",
    "parameters": {"type": "object", "required": ["target", "text"], "properties": {
        "target": {"type": "object", "required": ["path", "line"],
                   "properties": {"path": {"type": "string"}, "line": {"type": "integer"}}},
        "text": {"type": "string"}}}}}]
AG_START = [{"role": "system", "content": "You are a coding agent working in a repository. Act only through the tools."},
            {"role": "user", "content": "app.py line 3 has a typo: 'pritn' should be 'print'. "
                                        "First list the Python files, then fix the typo."}]
AG_ERROR = ('ValidationError: the previous call was rejected. Files may only be changed with edit_line, '
            'whose arguments must be {"target": {"path": <string>, "line": <integer>}, "text": <string>}. '
            'Retry the fix now.')


AG_MAX_TOKENS = 4096   # thinking models reason before calling (IBM's Granite 4.2 tool example allows 4096)
AG_FILE = "     1\timport sys\n     2\t\n     3\tpritn('hello')\n"


def agentic(label, out, url, n, model=None):
    """Structured tool calls across a multi-turn loop, including a correction after a validation error.

    Per loop: turn 1 any valid call (answered with a file list); turn 2 any valid call (answered with a
    validation error); then up to 3 correction turns, bash answered with the file, until a valid
    edit_line call with nested arguments. Any malformed turn is a stack failure and fails the gate at
    once; a loop that stays well-formed but never calls edit_line is inconclusive (a model choice, not a
    stack fault) and is replaced, up to n + 2 attempts.
    """
    lines = [f"## {label} (agentic, {'streamed' if STREAM else 'non-streamed'}: need {n} passing loops, at most {n + 2} attempts)",
             f"model id sent: {model or 'none'}"]
    passed = inconclusive = 0
    failed = False
    with open(f"{out}.{label}.jsonl", "a") as raw:
        for loop in range(1, n + 3):
            if passed == n or failed:
                break
            msgs, verdict = list(AG_START), "inconclusive"
            for turn in range(1, 6):
                body = {"messages": msgs, "tools": AG_TOOLS, "max_tokens": AG_MAX_TOKENS}
                if model:
                    body["model"] = model
                try:
                    r, issues = complete(url, body)
                    cls = "stream-defect" if issues else classify(r, AG_TOOLS)
                    m = r["choices"][0]["message"]
                    detail = f"finish={r['choices'][0]['finish_reason']} calls=" + json.dumps(
                        [(t["function"]["name"], t["function"].get("arguments")) for t in m.get("tool_calls") or []])[:150] \
                        + (f" DEFECTS: {'; '.join(issues)}" if issues else "")
                    raw.write(json.dumps({"label": label, "loop": loop, "turn": turn, "class": cls, "response": r}) + "\n")
                except Exception as e:
                    cls, detail, m = "server-error", f"{type(e).__name__}: {e}", None
                    raw.write(json.dumps({"label": label, "loop": loop, "turn": turn, "class": cls, "error": detail}) + "\n")
                lines.append(f"loop {loop} turn {turn}: {cls:<12} {detail}")
                print(lines[-1], flush=True)
                if cls in ("no-call", "budget"):   # prose, or budget exhausted with no markup: not a stack fault
                    break
                if cls != "pass":
                    verdict = "FAIL"
                    break
                calls = m["tool_calls"]
                names = [t["function"]["name"] for t in calls]
                if turn >= 3 and "edit_line" in names:
                    verdict = "PASS"
                    break
                if turn == 1:
                    reply = "app.py\nutil.py" if names[0] == "bash" else "ok"
                elif turn == 2:
                    reply = AG_ERROR
                else:
                    reply = AG_FILE
                msgs.append({"role": "assistant", "content": m.get("content") or "", "tool_calls": calls})
                for t in calls:
                    msgs.append({"role": "tool", "tool_call_id": t.get("id") or "call", "content": reply})
            lines.append(f"loop {loop}: {verdict}")
            passed += verdict == "PASS"
            inconclusive += verdict == "inconclusive"
            failed = verdict == "FAIL"
    ok = passed == n and not failed
    lines.append(f"RESULT {label}: agentic {'PASS' if ok else 'FAIL'} "
                 f"(passed {passed}/{n}, inconclusive {inconclusive}, stack failure {'yes' if failed else 'no'})")
    with open(out, "a") as f:
        f.write("\n".join(lines) + "\n\n")
    print(lines[-1])
    return 0 if ok else 1


def workaround(out, url):
    tmpl = call(url, "/props").get("chat_template") or ""
    old, new = "'<tool_call><function=' ~", "'<tool_call><func' ~ 'tion=' ~"
    if tmpl.count(old) != 1:
        raise SystemExit(f"expected the #29319 pattern exactly once, found {tmpl.count(old)}: not this template")
    fixed = tmpl.replace(old, new)
    if "<function=" in fixed:
        raise SystemExit("another literal '<function=' remains: detection would still match")
    with open(out, "w") as f:
        f.write(fixed)
    print(f"wrote {out}  sha256 {sha(fixed)}  (original {sha(tmpl)})")


def main(a):
    url = "http://127.0.0.1:8080"
    if "--url" in a:
        i = a.index("--url"); url = a[i + 1]; del a[i:i + 2]
    n = 10
    if "--n" in a:
        i = a.index("--n"); n = int(a[i + 1]); del a[i:i + 2]
    model = None
    if "--model" in a:
        i = a.index("--model"); model = a[i + 1]; del a[i:i + 2]
    no_props = "--no-props" in a
    if no_props:
        a.remove("--no-props")
    global STREAM
    STREAM = "--stream" in a
    if STREAM:
        a.remove("--stream")
    if len(a) == 3 and a[0] == "probe":
        return probe(a[1], a[2], url, n, model, no_props)
    if len(a) == 3 and a[0] == "agentic":
        return agentic(a[1], a[2], url, n if "--n" in sys.argv else 3, model)
    if len(a) == 2 and a[0] == "workaround":
        return workaround(a[1], url)
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
