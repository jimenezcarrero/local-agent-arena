#!/usr/bin/env python3
"""probe_toolcalls.py — can this llama-server's parser read the model's tool calls?

  probe_toolcalls.py probe <label> <evidence.txt> [--url URL] [--n 10]
      N requests offering one bash tool, thinking left at the template default.
      Appends to <evidence.txt>: server build, model, the chat template's sha256,
      the sha256 of a fixed conversation rendered by /apply-template, the
      effective sampling, and one classified line per probe; the raw responses
      go to <evidence>.<label>.jsonl. Exit 0 only if every probe passed.

  probe_toolcalls.py workaround <out.jinja> [--url URL]
      Writes the running server's chat template with the llama.cpp #29319
      workaround applied: the literal '<function=' split so template detection
      stops choosing the Qwen3-Coder parser; the rendered prompt must not change
      (compare the render sha256 of the two probe runs).

Classes: pass (finish=tool_calls, known tool, JSON arguments, no leaked tags);
sig-29319 (finish=length and a leaked '</parameter>' in the arguments or text:
the known parser mismatch); no-call (finished without a tool call);
server-error; other (including arguments that aren't an object with a
non-empty string "command"). If /props or /apply-template fails, the evidence
file still gets a header-error block and the exit code is 2.
"""
import hashlib, json, sys, urllib.request

TOOLS = [{"type": "function", "function": {"name": "bash", "description": "Run a shell command",
          "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}}]
PROBE = [{"role": "system", "content": "You are a coding agent. Use the bash tool to act."},
         {"role": "user", "content": "List the files in the current directory."}]
RENDER = PROBE + [
    {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "type": "function",
     "function": {"name": "bash", "arguments": "{\"command\": \"ls -la\"}"}}]},
    {"role": "tool", "tool_call_id": "c1", "content": "a.py\nb.py"}]


def call(url, path, body=None, timeout=900):
    req = urllib.request.Request(url + path, json.dumps(body).encode() if body is not None else None,
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


def classify(r):
    c = r["choices"][0]
    msg, fin = c["message"], c["finish_reason"]
    calls = msg.get("tool_calls") or []
    blob = (msg.get("content") or "") + "".join(t["function"].get("arguments") or "" for t in calls)
    if fin == "length" and "</parameter>" in blob:
        return "sig-29319"
    if fin == "tool_calls" and calls:
        for t in calls:
            a = t["function"].get("arguments") or ""
            if t["function"]["name"] != "bash" or "</" in a or "<tool_call>" in a:
                return "other"
            try:
                obj = json.loads(a)
            except (ValueError, TypeError):
                return "other"
            # the declared schema: an object with a non-empty string command
            if not isinstance(obj, dict) or not isinstance(obj.get("command"), str) or not obj["command"].strip():
                return "other"
        return "pass"
    if not calls and fin == "stop":
        return "no-call"
    return "other"


def header(url):
    p = call(url, "/props")
    tmpl = p.get("chat_template") or ""
    rendered = call(url, "/apply-template", {"messages": RENDER, "tools": TOOLS}).get("prompt", "")
    s = p.get("default_generation_settings", {}).get("params", {})
    samp = {k: s.get(k) for k in ("temperature", "top_k", "top_p", "min_p", "presence_penalty")}
    return p, tmpl, rendered, samp


def probe(label, out, url, n):
    try:
        p, tmpl, rendered, samp = header(url)
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
             f"chat_template sha256: {sha(tmpl)}",
             f"rendered fixed conversation sha256: {sha(rendered)}",
             f"sampling: {json.dumps(samp)}",
             f"probes: {n}, max_tokens 400, thinking unset"]
    counts = {}
    with open(f"{out}.{label}.jsonl", "a") as raw:
        for i in range(1, n + 1):
            try:
                r = call(url, "/v1/chat/completions", {"messages": PROBE, "tools": TOOLS, "max_tokens": 400})
                cls = classify(r)
                c = r["choices"][0]
                args = [t["function"].get("arguments") for t in c["message"].get("tool_calls") or []]
                detail = f"finish={c['finish_reason']} tokens={r['usage']['completion_tokens']} args={json.dumps(args)[:120]}"
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
    if len(a) == 3 and a[0] == "probe":
        return probe(a[1], a[2], url, n)
    if len(a) == 2 and a[0] == "workaround":
        return workaround(a[1], url)
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
