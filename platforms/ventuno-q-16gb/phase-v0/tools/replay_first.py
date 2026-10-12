#!/usr/bin/env python3
"""replay_first.py <request.json> <port> <n> <out dir> <label> (D141, D142) — send pi's captured first chat request,
byte for byte, n times to http://127.0.0.1:<port>/v1/chat/completions, one after another, and record whether each reply
contains a tool call.

Each try has ONE total deadline, TIMEOUT_S (default 600 s, as pi_smoke.py's `timeout 600 pi`), measured with a monotonic
clock over connect, headers and body; long quiet periods (a slow prefill) are fine until the deadline. The client is a
minimal HTTP/1.1 reader over a raw socket (Connection: close; chunked, Content-Length or close-delimited bodies), so a
deadline never leaves a half-read buffered response; on expiry the socket is closed, which cancels the server task.

Outcomes (D142, Codex review of 15c6fa6):
  tool     HTTP 200, a COMPLETE response (SSE: a finish_reason and "data: [DONE]"; JSON: choices[0].finish_reason) with
           >= 1 complete tool call: a function name and arguments that assemble to a JSON object
  no_tool  HTTP 200, a complete response, no tool call fragment at all
  timeout  the deadline expired; the partial bytes are kept and partial tool-call fragments are counted separately
  error    anything else: HTTP != 200, a transport error, a malformed or truncated body (incomplete chunked encoding,
           missing finish/[DONE], bad JSON), or a tool call that does not assemble (no name, arguments not a JSON object)
Per try: <out dir>/try-NN.txt (raw body bytes as received) and one line in <out dir>/replay.jsonl. <out dir> must not
exist yet (no stale tries can mix in). Prints "RESULT <label>: first-reply tool calls k/n (no_tool a, timeout b,
error c)". The usage-only SSE event that llama.cpp sends after the finish chunk when the request asks for
stream_options.include_usage (pi does) is accepted and recorded (D143); an event with an "error" key, or one with
neither choices nor usage, is malformed. Exit 0 only if no try is an error (timeouts are results); 1 if any try is an error; 2 on bad arguments."""
import json, os, select, socket, sys, time


def http_post(port, body, deadline):
    """-> (status or None, body bytes, complete bool, timed_out bool, note)."""
    buf = b""; timed_out = False
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=max(0.1, deadline - time.monotonic()))
    except OSError as e:
        return None, b"", False, time.monotonic() >= deadline, f"connect: {e}"
    try:
        s.setblocking(False)
        req = (b"POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
               b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body)) + body
        s.setblocking(True); s.settimeout(max(0.1, deadline - time.monotonic())); s.sendall(req); s.setblocking(False)
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                timed_out = True; break
            r, _, _ = select.select([s], [], [], min(left, 30))
            if not r:
                continue
            try:
                d = s.recv(65536)
            except (BlockingIOError, InterruptedError):
                continue
            if not d:
                break
            buf += d
    except OSError as e:
        return None, buf, False, False, f"transport: {e}"
    finally:
        s.close()
    head, sep, rest = buf.partition(b"\r\n\r\n")
    if not sep:
        return None, b"", False, timed_out, "no complete headers"
    lines = head.split(b"\r\n")
    try:
        status = int(lines[0].split()[1])
    except (IndexError, ValueError):
        return None, rest, False, timed_out, "bad status line"
    hdr = {k.strip().lower(): v.strip() for k, _, v in (l.decode("latin-1").partition(":") for l in lines[1:])}
    if hdr.get("transfer-encoding", "").lower() == "chunked":
        body, i, done = b"", 0, False
        while True:
            j = rest.find(b"\r\n", i)
            if j < 0:
                break
            try:
                size = int(rest[i:j].split(b";")[0], 16)
            except ValueError:
                return status, body, False, timed_out, "bad chunk size"
            if size == 0:
                done = True; break
            if len(rest) < j + 2 + size + 2:
                body += rest[j + 2:j + 2 + size]; break
            body += rest[j + 2:j + 2 + size]; i = j + 2 + size + 2
        return status, body, done, timed_out, "" if done else "incomplete chunked body"
    if "content-length" in hdr:
        n = int(hdr["content-length"])
        return status, rest[:n], len(rest) >= n, timed_out, "" if len(rest) >= n else "short body"
    return status, rest, not timed_out, timed_out, ""


def parse(raw):
    """-> dict(valid, complete, calls (assembled, valid), fragments, finish, content, reasoning, problem)."""
    out = {"valid": True, "complete": False, "calls": 0, "fragments": 0, "finish": None, "content": "", "reasoning": "", "problem": "", "usage": None}
    text = raw.decode("utf-8", "replace")
    acc = {}
    if text.lstrip().startswith("{"):
        try:
            ch = json.loads(text)["choices"][0]; m = ch.get("message", {})
        except (ValueError, KeyError, IndexError, TypeError):
            out.update(valid=False, problem="bad JSON body"); return out
        out["finish"] = ch.get("finish_reason"); out["complete"] = out["finish"] is not None
        out["content"] = m.get("content") or ""; out["reasoning"] = m.get("reasoning_content") or ""
        for k, tc in enumerate(m.get("tool_calls") or []):
            f = tc.get("function", {}); acc[k] = {"name": f.get("name") or "", "args": f.get("arguments") or ""}
    else:
        done = False
        for line in text.splitlines():
            if not line.startswith("data:"):
                continue
            d = line[5:].strip()
            if d == "[DONE]":
                done = True; continue
            try:
                ev = json.loads(d); chs = ev["choices"]
            except (ValueError, KeyError, TypeError):
                out.update(valid=False, problem="bad SSE event"); return out
            if "error" in ev:
                out.update(valid=False, problem="error event"); return out
            if chs == [] and isinstance(ev.get("usage"), dict):  # D143: the usage-only chunk (stream_options.include_usage)
                out["usage"] = ev["usage"]; continue
            try:
                ch = chs[0]
            except (IndexError, TypeError):
                out.update(valid=False, problem="SSE event without choices or usage"); return out
            dl = ch.get("delta", {}) or {}
            for tc in dl.get("tool_calls") or []:
                k = tc.get("index", 0); a = acc.setdefault(k, {"name": "", "args": ""}); f = tc.get("function", {}) or {}
                a["name"] += f.get("name") or ""; a["args"] += f.get("arguments") or ""
            out["content"] += dl.get("content") or ""; out["reasoning"] += dl.get("reasoning_content") or ""
            out["finish"] = ch.get("finish_reason") or out["finish"]
        out["complete"] = done and out["finish"] is not None
    out["fragments"] = len(acc)
    for a in acc.values():
        try:
            ok = bool(a["name"]) and isinstance(json.loads(a["args"] or "null"), dict)
        except ValueError:
            ok = False
        if ok:
            out["calls"] += 1
        else:
            out["problem"] = "a tool call does not assemble (name or JSON-object arguments missing)"
    return out


def main(req, port, n, out, label):
    body = open(req, "rb").read(); json.loads(body)  # must be valid JSON
    if os.path.exists(out):
        print(f"{out} already exists; refusing to mix tries"); return 2
    os.makedirs(out); to = float(os.environ.get("TIMEOUT_S", "600"))
    cnt = {"tool": 0, "no_tool": 0, "timeout": 0, "error": 0}
    for i in range(1, n + 1):
        t0 = time.monotonic()
        status, raw, complete, timed_out, note = http_post(port, body, t0 + to)
        p = parse(raw)
        if timed_out:
            outcome = "timeout"
        elif status != 200 or not complete or not p["valid"] or not p["complete"] or p["problem"]:
            outcome = "error"
        else:
            outcome = "tool" if p["calls"] else ("no_tool" if p["fragments"] == 0 else "error")
        cnt[outcome] += 1
        open(os.path.join(out, f"try-{i:02d}.txt"), "wb").write(raw)
        with open(os.path.join(out, "replay.jsonl"), "a") as f:
            f.write(json.dumps({"try": i, "http": status, "outcome": outcome, "tool_calls": p["calls"],
                                "tool_fragments": p["fragments"], "finish": p["finish"], "complete": complete and p["complete"],
                                "problem": note or p["problem"], "content_chars": len(p["content"]),
                                "reasoning_chars": len(p["reasoning"]), "content_head": p["content"][:200], "usage": p["usage"],
                                "seconds": round(time.monotonic() - t0, 1)}) + "\n")
    print(f"RESULT {label}: first-reply tool calls {cnt['tool']}/{n} (no_tool {cnt['no_tool']}, timeout {cnt['timeout']}, error {cnt['error']})")
    return 1 if cnt["error"] else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) != 5:
        raise SystemExit(__doc__)
    sys.exit(main(a[0], int(a[1]), int(a[2]), a[3], a[4]))
