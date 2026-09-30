#!/usr/bin/env python3
"""speed_probe.py — prompt-processing and generation speed through any OpenAI-compatible server.

  speed_probe.py <label> <evidence.txt> [--depths 8192,16384] [--gen 128] [--url URL] [--model ID]

One measurement method for every runtime (llama-server, GenieX serve, ...), so
routes are compared like for like. Per depth: a fresh prompt of about that many
tokens (the repo's own Markdown, a unique first line so no prefix cache can
help; sizing corrects itself after the first depth), streamed; prefill = prompt tokens / time to first token, decode =
(generated tokens - 1) / (last token time - first token time). Token counts
come from the server's usage report when it sends one ("method=usage"),
otherwise from streamed chunks ("method=chunks", prompt size unknown).
llama-server's own timings are logged beside ours as a cross-check.
Appends one RESULT line per depth to <evidence.txt>.
"""
import json, pathlib, sys, time, urllib.request, uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]


def corpus(chars):
    text = "\n\n".join(p.read_text(errors="replace") for p in sorted(ROOT.glob("**/*.md"))
                       if ".git" not in p.parts)
    while len(text) < chars:
        text += "\n\n" + text
    return text[:chars]


def measure(url, model, depth, gen, cpt):
    chars = int(depth * cpt)
    body = {"messages": [{"role": "user", "content": f"Run {uuid.uuid4()}.\n\n" + corpus(chars)
                          + "\n\nSummarize the text above in one paragraph."}],
            "max_tokens": gen, "stream": True, "stream_options": {"include_usage": True},
            "cache_prompt": False}
    if model:
        body["model"] = model
    req = urllib.request.Request(url + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t0 = time.monotonic(); first = last = None; chunks = 0; usage = timings = None
    with urllib.request.urlopen(req, timeout=3600) as r:
        for raw in r:
            line = raw.decode(errors="replace").strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            ev = json.loads(line[5:])
            usage = ev.get("usage") or usage
            timings = ev.get("timings") or timings
            for ch in ev.get("choices") or []:
                d = ch.get("delta") or {}
                if d.get("content") or d.get("reasoning_content"):
                    now = time.monotonic()
                    first = first or now; last = now; chunks += 1
    if first is None:
        return "no tokens generated", cpt
    ttft = first - t0
    if usage and usage.get("completion_tokens"):
        pt, gt, method = usage.get("prompt_tokens"), usage["completion_tokens"], "usage"
    else:
        pt, gt, method = None, chunks, "chunks"
    prefill = f"{pt / ttft:.1f}" if pt else "n/a"
    decode = f"{(gt - 1) / (last - first):.2f}" if gt > 1 and last > first else "n/a"
    s = (f"depth={depth} prompt_tokens={pt} ttft={ttft:.1f}s prefill_tps={prefill} "
         f"gen_tokens={gt} decode_tps={decode} method={method}")
    if gt < 32:
        s += " LOW_SAMPLE(<32 generated)"
    if timings:
        s += (f" server_prompt_tps={timings.get('prompt_per_second', 0):.1f}"
              f" server_decode_tps={timings.get('predicted_per_second', 0):.2f}")
    return s, (chars / pt if pt else cpt)


def main(a):
    opts = {"--depths": "8192,16384", "--gen": "128", "--url": "http://127.0.0.1:8080", "--model": None}
    for k in list(opts):
        if k in a:
            i = a.index(k); opts[k] = a[i + 1]; del a[i:i + 2]
    if len(a) != 2:
        raise SystemExit(__doc__)
    label, out = a
    with open(out, "a") as f:
        f.write(f"## {label}  url={opts['--url']} model={opts['--model'] or 'none'} gen={opts['--gen']}\n")
        cpt = 3.2  # characters per token, corrected after each measurement for this model's tokenizer
        for d in (int(x) for x in opts["--depths"].split(",")):
            try:
                res, cpt = measure(opts["--url"], opts["--model"], d, int(opts["--gen"]), cpt)
            except Exception as e:  # a failed depth is recorded, never skipped silently
                res = f"depth={d} ERROR {type(e).__name__}: {e}"
            line = f"RESULT {label}: {res}"
            print(line, flush=True); f.write(line + "\n")
        f.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
