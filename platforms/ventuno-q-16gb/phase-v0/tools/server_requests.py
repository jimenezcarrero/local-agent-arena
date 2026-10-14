#!/usr/bin/env python3
"""server_requests.py <server.log>   (D171) - what every request of a llama-server session cost, from its log (-lv 4).
Per task: the prompt's tokens (task.n_tokens), the tokens evaluated (prompt eval time ... / N tokens), so the tokens
taken from the cache (the difference), the prefill and decode times, and whether the server forced a full
re-processing. Then the session's totals and the largest prompt-cache state it logged (prompts, MiB, its limit).
A report, not a check: reuse and cache size are recorded for every session (pi's real requests included), never
gated here. Exit 1 only if the log cannot be read or holds no completed request."""
import re, sys

rows, order, full, state = {}, [], set(), None
try:
    lines = open(sys.argv[1], errors="replace").read().splitlines()
except OSError as e:
    print(f"RESULT server-requests: unreadable ({e})"); sys.exit(1)
for l in lines:
    m = re.search(r"\| task (\d+) \| (.*)", l)
    if m:
        t, rest = int(m.group(1)), m.group(2)
        if (n := re.search(r"new prompt, .*task\.n_tokens = (\d+)", rest)):
            if t not in rows:
                order.append(t)
            rows[t] = {"prompt": int(n.group(1))}
        elif t in rows and (n := re.search(r"prompt eval time =\s*([\d.]+) ms /\s*(\d+) tokens", rest)):
            rows[t]["prefill_ms"], rows[t]["evaluated"] = float(n.group(1)), int(n.group(2))
        elif t in rows and (n := re.search(r"^\s*eval time =\s*([\d.]+) ms /\s*(\d+) tokens", rest)):
            rows[t]["decode_ms"], rows[t]["decoded"] = float(n.group(1)), int(n.group(2))
        if "forcing full prompt re-processing" in rest:
            full.add(t)
    if (n := re.search(r"cache state: (\d+) prompts, ([\d.]+) MiB \(limits: ([\d.]+) MiB", l)):
        s = (float(n.group(2)), int(n.group(1)), float(n.group(3)))
        state = max(state, s) if state else s
done = [t for t in order if "evaluated" in rows[t]]
print("task prompt evaluated cached prefill_s decode_tokens decode_s full_reprocess")
for t in done:
    r = rows[t]
    print(f"{t} {r['prompt']} {r['evaluated']} {r['prompt'] - r['evaluated']} {r['prefill_ms'] / 1000:.1f} "
          f"{r.get('decoded', '?')} {r.get('decode_ms', 0) / 1000:.1f} {'yes' if t in full else 'no'}")
if not done:
    print("RESULT server-requests: no completed request in the log"); sys.exit(1)
P = sum(rows[t]["prompt"] for t in done); E = sum(rows[t]["evaluated"] for t in done)
big = max(done, key=lambda t: rows[t]["prompt"])
print(f"PROMPT CACHE: largest logged state {state[1]} prompts, {state[0]:.1f} MiB (limit {state[2]:.0f} MiB)" if state
      else "PROMPT CACHE: no cache state logged")
print(f"RESULT server-requests: {len(done)} requests, prompt tokens {P}, evaluated {E}, from cache {P - E} "
      f"({(P - E) / max(P, 1):.1%}); full re-processing forced {len(full & set(done))}; largest prompt {rows[big]['prompt']} "
      f"tokens, prefill {rows[big]['prefill_ms'] / 1000:.1f}s")
