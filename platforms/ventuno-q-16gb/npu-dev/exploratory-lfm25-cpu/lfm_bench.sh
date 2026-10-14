#!/bin/bash
# Exploratory CPU check of LFM2.5-24B-A2B AD-IQ3_XXS (not campaign evidence). Big cores only (cpu0-3, A78C).
# 1) llama-bench: pp512 / tg128 at depth 0 and 8192.  2) llama-server without and with n-gram speculation:
#    two requests each (pi's recorded first request; a code edit that copies a file), same seed.
set -uo pipefail
B=~/v0/llama.cpp/build-cpu-v82/bin; M=~/v0/models/lfm25/LFM2.5-24B-A2B-AD-IQ3_XXS.gguf
O=~/bench-runs/lfm25-explore; mkdir -p $O; cd ~/bench-runs || exit 1
T="-t 4 --cpu-mask 0xF --cpu-strict 1"
log() { echo "$(date -Is) $*" | tee -a $O/run.txt; }
pgrep -x llama-server >/dev/null && { log "ABORT: a llama-server is running"; exit 3; }
free -m > $O/free-start.txt
log "llama-bench start"
$B/llama-bench -m $M $T -p 512 -n 128 -d 0,8192 -r 2 -o md > $O/llama-bench.md 2> $O/llama-bench.err; log "llama-bench rc $?"
cat $O/llama-bench.md | tee -a $O/run.txt
python3 - $O <<'PY'
import json, sys
o = sys.argv[1]
req = json.load(open(__import__("os").path.expanduser("~/bench-runs/v0/v0p-pi/v0p-D1/first-request.json")))
pi = {"messages": req["messages"], "tools": req["tools"], "max_tokens": 1024, "seed": 42, "stream": False}
src = "".join(open("/usr/lib/python3.12/textwrap.py").readlines()[:160])
edit = {"messages": [{"role": "user", "content": "Here is a Python file:\n\n```python\n" + src + "```\n\nReturn the complete file "
        "unchanged except that the class TextWrapper is renamed to LineWrapper everywhere. Output only the file."}],
        "max_tokens": 2048, "seed": 42, "stream": False}
json.dump(pi, open(o + "/req-pi.json", "w")); json.dump(edit, open(o + "/req-edit.json", "w"))
PY
srv() { local tag=$1; shift
  setsid $B/llama-server -m $M $T -c 16384 --host 127.0.0.1 --port 8090 --jinja "$@" > $O/server-$tag.log 2>&1 < /dev/null & local pid=$!
  for i in $(seq 1 120); do curl -sf -m 2 http://127.0.0.1:8090/health >/dev/null && break; sleep 2; done
  log "server $tag ready (pid $pid) $*"
  for r in pi edit; do
    curl -s -m 3600 http://127.0.0.1:8090/v1/chat/completions -H 'Content-Type: application/json' -d @$O/req-$r.json > $O/resp-$tag-$r.json
    python3 - $O/resp-$tag-$r.json $tag $r <<'PY' | tee -a $O/run.txt
import json, sys
d = json.load(open(sys.argv[1])); t = d.get("timings", {}); u = d.get("usage", {})
m = (d.get("choices") or [{}])[0].get("message", {})
print(f"RESULT {sys.argv[2]} {sys.argv[3]}: prompt {u.get('prompt_tokens')} tok at {t.get('prompt_per_second', 0):.1f} tok/s; "
      f"generated {u.get('completion_tokens')} at {t.get('predicted_per_second', 0):.2f} tok/s; "
      f"draft {t.get('draft_n')} accepted {t.get('draft_n_accepted')}; tool calls {len(m.get('tool_calls') or [])}; "
      f"finish {(d.get('choices') or [{}])[0].get('finish_reason')}")
PY
  done
  kill -TERM $pid; sleep 5; kill -KILL $pid 2>/dev/null; wait $pid 2>/dev/null; }
srv base
srv ngram --spec-type ngram-mod
free -m > $O/free-end.txt; log "done"
