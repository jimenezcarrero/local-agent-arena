#!/usr/bin/env python3
"""replay_first.py <request.json> <port> <n> <out dir> <label> (D141) — send pi's captured first chat request, byte for
byte, n times to http://127.0.0.1:<port>/v1/chat/completions, one after another, and record whether each reply contains a
tool call. Streaming (SSE) and plain JSON replies are both parsed. Per try: <out dir>/try-NN.txt (raw response) and one
line in <out dir>/replay.jsonl {try, http, outcome, tool_calls, finish, content_chars, reasoning_chars, content_head,
seconds}. outcome: tool (at least one tool call), no_tool (finished without one), timeout (no end within TIMEOUT_S,
default 600 s like pi_smoke; the connection is closed, which cancels the server task), error (HTTP != 200 or a broken
stream). Prints "RESULT <label>: first-reply tool calls k/n (no_tool a, timeout b, error c)". Exit 0 if every try got
HTTP 200 (timeouts are results), 1 otherwise. Standard library only."""
import http.client, json, os, socket, sys, time


def parse(raw):
    """-> (tool_calls, finish, content, reasoning, ok) from an SSE or JSON chat completion body."""
    calls, finish, content, reasoning, ok = 0, None, "", "", False
    text = raw.decode("utf-8", "replace")
    if text.lstrip().startswith("{"):
        try:
            ch = json.loads(text)["choices"][0]
        except (ValueError, KeyError, IndexError):
            return 0, None, "", "", False
        m = ch.get("message", {})
        return len(m.get("tool_calls") or []), ch.get("finish_reason"), m.get("content") or "", m.get("reasoning_content") or "", True
    ids = set()
    for line in text.splitlines():
        if not line.startswith("data:"):
            continue
        d = line[5:].strip()
        if d == "[DONE]":
            ok = True; continue
        try:
            ch = json.loads(d)["choices"][0]
        except (ValueError, KeyError, IndexError):
            continue
        dl = ch.get("delta", {})
        for tc in dl.get("tool_calls") or []:
            ids.add(tc.get("index", tc.get("id")))
        content += dl.get("content") or ""; reasoning += dl.get("reasoning_content") or ""
        finish = ch.get("finish_reason") or finish
    return len(ids), finish, content, reasoning, ok or finish is not None


def main(req, port, n, out, label):
    body = open(req, "rb").read(); json.loads(body)  # must be valid JSON
    os.makedirs(out, exist_ok=True); to = float(os.environ.get("TIMEOUT_S", "600"))
    cnt = {"tool": 0, "no_tool": 0, "timeout": 0, "error": 0}; allok = True
    for i in range(1, n + 1):
        t0 = time.time(); raw = b""; status = None; outcome = "error"
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)  # per-read idle timeout; the deadline is checked per read
            c.request("POST", "/v1/chat/completions", body=body, headers={"Content-Type": "application/json"})
            r = c.getresponse(); status = r.status
            while True:
                left = to - (time.time() - t0)
                if left <= 0:
                    outcome = "timeout"; break
                try:
                    chunk = r.read1(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                raw += chunk
            c.close()
        except OSError:
            pass
        calls, finish, content, reasoning, ok = parse(raw)
        if status != 200:
            outcome = "error"; allok = False
        elif outcome != "timeout":
            outcome = "tool" if calls else ("no_tool" if ok else "error")
        cnt[outcome] += 1
        open(os.path.join(out, f"try-{i:02d}.txt"), "wb").write(raw)
        with open(os.path.join(out, "replay.jsonl"), "a") as f:
            f.write(json.dumps({"try": i, "http": status, "outcome": outcome, "tool_calls": calls, "finish": finish,
                                "content_chars": len(content), "reasoning_chars": len(reasoning),
                                "content_head": content[:200], "seconds": round(time.time() - t0, 1)}) + "\n")
    print(f"RESULT {label}: first-reply tool calls {cnt['tool']}/{n} (no_tool {cnt['no_tool']}, timeout {cnt['timeout']}, error {cnt['error']})")
    return 0 if allok else 1


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) != 5:
        raise SystemExit(__doc__)
    sys.exit(main(a[0], int(a[1]), int(a[2]), a[3], a[4]))
