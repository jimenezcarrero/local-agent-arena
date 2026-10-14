#!/bin/bash
# Exploratory CPU check 2 of LFM2.5-24B-A2B AD-IQ3_XXS (not campaign evidence). Big cores only (cpu0-3).
#  a) base server: 20 replays of pi's recorded first request (no seed: llama.cpp samples with the GGUF's defaults,
#     temp 0.1, top_k 50, repeat 1.05); tool-call rate in the first reply, as the NeoHorse diagnostic (D141 D1-D6)
#  b) the code-edit request with max_tokens 6144 (room past the reasoning), base vs --spec-type ngram-mod, seed 42
set -uo pipefail
B=~/v0/llama.cpp/build-cpu-v82/bin; M=~/v0/models/lfm25/LFM2.5-24B-A2B-AD-IQ3_XXS.gguf
O=~/bench-runs/lfm25-explore/run2; mkdir -p $O; cd ~/bench-runs || exit 1
T="-t 4 --cpu-mask 0xF --cpu-strict 1"
log() { echo "$(date -Is) $*" | tee -a $O/run.txt; }
pgrep -x llama-server >/dev/null && { log "ABORT: a llama-server is running"; exit 3; }
python3 - $O <<'PY'
import json, sys
o = sys.argv[1]; e = json.load(open(o + "/../req-edit.json")); e["max_tokens"] = 6144
json.dump(e, open(o + "/req-edit6k.json", "w"))
p = json.load(open(o + "/../req-pi.json")); p.pop("seed", None); json.dump(p, open(o + "/req-pi-noseed.json", "w"))
PY
res() { python3 - "$@" <<'PY' | tee -a $O/run.txt
import json, sys
d = json.load(open(sys.argv[1])); t = d.get("timings", {}); u = d.get("usage", {})
c = (d.get("choices") or [{}])[0]; m = c.get("message", {})
calls = m.get("tool_calls") or []
print(f"RESULT {sys.argv[2]}: prompt {u.get('prompt_tokens')} (cached {t.get('cache_n')}) at {t.get('prompt_per_second', 0):.1f} tok/s; "
      f"generated {u.get('completion_tokens')} at {t.get('predicted_per_second', 0):.2f} tok/s; draft {t.get('draft_n')} accepted "
      f"{t.get('draft_n_accepted')}; finish {c.get('finish_reason')}; reasoning {len(m.get('reasoning_content') or '')} chars, "
      f"content {len(m.get('content') or '')} chars; calls {[x['function']['name'] for x in calls]}")
PY
}
srv() { local tag=$1; shift
  setsid $B/llama-server -m $M $T -c 16384 --host 127.0.0.1 --port 8090 --jinja "$@" > $O/server-$tag.log 2>&1 < /dev/null & SPID=$!
  for i in $(seq 1 120); do curl -sf -m 2 http://127.0.0.1:8090/health >/dev/null && break; sleep 2; done
  log "server $tag ready (pid $SPID) $*"; }
stop() { kill -TERM $SPID; sleep 5; kill -KILL $SPID 2>/dev/null; wait $SPID 2>/dev/null; }
ask() { curl -s -m 7200 http://127.0.0.1:8090/v1/chat/completions -H 'Content-Type: application/json' -d @$1 > $2; }
srv base
for i in $(seq 1 20); do ask $O/req-pi-noseed.json $O/resp-pi-$i.json; res $O/resp-pi-$i.json "pi replay $i"; done
python3 - $O <<'PY' | tee -a $O/run.txt
import json, sys, glob
o = sys.argv[1]; n = k = 0
for f in sorted(glob.glob(o + "/resp-pi-*.json")):
    d = json.load(open(f)); m = (d.get("choices") or [{}])[0].get("message", {}); n += 1; k += bool(m.get("tool_calls"))
print(f"SUMMARY pi first-reply tool calls {k}/{n}")
PY
ask $O/req-edit6k.json $O/resp-edit-base.json; res $O/resp-edit-base.json "edit base 6144"
stop
srv ngram --spec-type ngram-mod
ask $O/req-edit6k.json $O/resp-edit-ngram.json; res $O/resp-edit-ngram.json "edit ngram-mod 6144"
grep -h "draft acceptance" $O/server-ngram.log | tail -1 | tee -a $O/run.txt
stop; log "done"
