#!/usr/bin/env python3
"""v0f_stress.py — NPU hang diagnostic workload (D122), run by run_v0e.sh with OUT, URL, SPID, LABEL set.
Sends N_REQ (default 40) sequential chat requests to the server: each a new nonce + a frozen-corpus prompt of a size
drawn from {300, 500, 1000, 1700} tokens and max_tokens from {64, 128, 300} (a fixed seeded sequence per label, so
both arms see the same mix), no tools, server-default sampling, cache_prompt false. The sizes cover the requests that
hung before (287-631-token probes, the 1,642-token pi request, decodes to 278 tokens).
Records one JSON line per request in $OUT/stress.jsonl (index, prompt/completion tokens, prefill/decode tok/s,
seconds, slot when reported, error) and the server's GGML_HEXAGON_* environment from /proc/$SPID/environ in
$OUT/server-env.txt (proof of the arm's setting). Stops at the first request error and exits 5 if the server is gone
(a watchdog kill after an NPU stall), 1 on any other error, 0 when all N_REQ completed."""
import json, os, random, sys, time, urllib.error, urllib.request, uuid

sys.path.insert(0, os.path.expanduser("~/v0/measure/suite/tools"))
from speed_probe import corpus  # frozen corpus (measurement commit 7badb21)

OUT, URL, SPID, LABEL = os.environ["OUT"], os.environ["URL"], os.environ["SPID"], os.environ["LABEL"]
N = int(os.environ.get("N_REQ", "40"))
try:
    env = open(f"/proc/{SPID}/environ", "rb").read().split(b"\0")
    hx = sorted(e.decode(errors="replace") for e in env if e.startswith(b"GGML_HEXAGON"))
except OSError as e:
    hx = [f"unreadable: {e}"]
open(os.path.join(OUT, "server-env.txt"), "w").write("\n".join(hx) + "\n")
print("server env:", " ".join(hx), flush=True)
rng = random.Random(LABEL.split("-")[-1])  # the session index: arm W and arm B session k share a sequence
text = corpus(1700 * 4)
log = open(os.path.join(OUT, "stress.jsonl"), "a")
for i in range(1, N + 1):
    ptok, gen = rng.choice((300, 500, 1000, 1700)), rng.choice((64, 128, 300))
    body = {"messages": [{"role": "user", "content": f"Run {uuid.uuid4()}.\n\n" + text[:int(ptok * 3.2)]
                          + "\n\nWrite a detailed summary of the text above."}],
            "max_tokens": gen, "cache_prompt": False}
    t0 = time.monotonic(); rec = {"i": i, "target_prompt": ptok, "max_tokens": gen}
    try:
        req = urllib.request.Request(URL + "/v1/chat/completions", json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=900) as r:
            d = json.loads(r.read())
        u, t = d.get("usage") or {}, d.get("timings") or {}
        rec.update(prompt=u.get("prompt_tokens"), completion=u.get("completion_tokens"),
                   prefill=t.get("prompt_per_second"), decode=t.get("predicted_per_second"), ok=True)
    except (urllib.error.URLError, OSError, ValueError) as e:
        rec.update(ok=False, error=f"{type(e).__name__}: {e}"[:300])
    rec["seconds"] = round(time.monotonic() - t0, 1)
    log.write(json.dumps(rec) + "\n"); log.flush()
    print(json.dumps(rec), flush=True)
    if not rec["ok"]:
        gone = not os.path.exists(f"/proc/{SPID}")
        print(f"STOP at request {i}: {'server gone' if gone else 'request error'}")
        sys.exit(5 if gone else 1)
print(f"RESULT {LABEL}: {N}/{N} requests completed")
