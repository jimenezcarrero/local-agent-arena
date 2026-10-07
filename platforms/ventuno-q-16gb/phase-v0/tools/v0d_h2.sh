#!/bin/bash
# V0d 9B H, completion (D64): H r2, r3 and the tool gates, each on a recovered NPU. The load timeline
# (runs/v0d-final-9b-h/load-timeline.txt) shows the degraded state follows successful 9B 3-session loads (after 7,
# then 2), never 4B-only sequences; idle recovery ~16 min in 3 of 4 cases. Before each H load: probe the base 4B
# (load + 512) every 15 min until it passes (up to 3 h), then 3 min idle. Stops at an NPU hang.
set -uo pipefail
ST=~/bench-runs/v0/v0d/h-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=~/bench-runs/v0/v0d-final-9b-h
source <(sed -n '/^say()/,/^step()/p' ~/v0/v0d_h.sh | sed '$d'; sed -n '/^step()/,/sleep 180; }$/p' ~/v0/v0d_h.sh)
ready() { for i in $(seq 1 12); do sleep 900; local lab=probe-$(date +%H%M)
    timeout -k 60 900 ~/v0/run_route.sh $lab v0d-final-9b-h --depths 512 --nctx 40960 -- $A > /dev/null 2>&1; killall_srv
    local r=$(grep -o 'RESULT .*' $O/$lab/run.txt | tail -1 | cut -c1-50); say "PROBE $lab | $r"
    hung && { say "STOP: hang during a probe"; exit 2; }
    case "$r" in *PASS*) sleep 180; return 0;; esac; done
  say "NPU did not recover in 3 h"; exit 1; }
say "H completion start (pid $$)"
ready; step 9b-H-r2b 512,8192,16384,32768 5400 "$H"
ready; step 9b-H-r3b 512,8192,16384,32768 5400 "$H"
ready; say "TOOLS 9b-H"; PHASE=v0d-final-9b-h timeout -k 60 9000 ~/v0/run_v0c.sh 9b-H-tools-b llama 0 -- $H > /dev/null 2>&1; killall_srv
say "TOOLS 9b-H: $(grep -o 'RESULT .*' $O/9b-H-tools-b/run.txt | tail -1 | cut -c1-140)"; hung && { say "STOP: hang in tools"; exit 2; }
say "H completion done"
