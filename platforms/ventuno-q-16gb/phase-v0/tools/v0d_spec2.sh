#!/bin/bash
# V0d speculative-decoding sweep, round 2 (D72): make the MTP draft cheap. Round 1: 4B base-MTP acceptance 0.81 but 111 ms per
# drafted token on the CPU (8 default threads, --no-repack) and prefill 284 -> 82 (the draft processes every prompt
# position through its MTP layer on the CPU). Here: the MTP layer on the NPU, or a faster CPU draft.
# runs (ranking only); winners then go through the D68 admission set. Starts after the hang diagnosis.
# Targets: 4B A (2 sessions, -ngl 99) and 9B H (3 sessions, MBUF 256, -ngl 33 --no-op-offload -t 4), both
# --ctx-checkpoints 0 -c 40960. Sweep runs use --cache-ram 2048 (drafts need RAM; cache size does not change speed,
# D53) and record every draft on the CPU (--device-draft none) so NPU mappings stay as admitted.
# Each run: fresh server, depths 512/8K/16K, draft acceptance from the server log. A control run without speculation
# precedes each model's variants. Every 9B load waits for a passing baseline probe (D64).
# Fail-closed: EVIDENCE stops; HANG or DEVFAULT (NPU runtime abort, D71) is recorded, then recovery and continue (cap: 3 hangs); a config that fails to
# load twice is recorded as unsupported and skipped.
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=v0d-spec2; ST=~/bench-runs/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; DR=~/v0/models/drafts; O=~/bench-runs/v0/$PH
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
T4="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
T9="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
CPUD="--device-draft none --spec-draft-ngl 0"
HANGS=0
ready() { for i in $(seq 1 13); do [ $i = 1 ] && [ "${1:-wait}" = now ] || sleep 900
    local lab=probe-$(date +%H%M%S) wd0=$(wdcount)
    timeout -k 60 900 ~/v0/run_route.sh $lab $PH --depths 512 --nctx 40960 -- $BASE > /dev/null 2>&1; local rc=$?; killall_srv
    local c=$(classify $O/$lab $rc $wd0); say "PROBE $lab: $c"
    case $c in PASS) sleep 180; return 0;; HANG|DEVFAULT) HANGS=$((HANGS+1)); [ $HANGS -ge 3 ] && { say "STOP: 3 hangs"; exit 5; };; EVIDENCE) say "STOP: probe EVIDENCE"; exit 2;; esac; done
  say "STOP: NPU not ready after 3 h"; exit 1; }
acc() { sed 's/\x1b\[[0-9;]*m//g' $1/server.log 2>/dev/null | grep -aoE '[0-9]+ accepted / *[0-9]+ generated' | awk '{a+=$1; g+=$4} END{if(g>0) printf "acceptance %d/%d = %.2f", a, g, a/g; else print "acceptance n/a"}'; }
run() { local lab=$1 pre=$2; shift 2; local cmd="$*"
  for attempt in 1 2; do [ $pre = probe ] && ready now
    say "START $lab (attempt $attempt)"; local wd0=$(wdcount)
    timeout -k 60 3600 ~/v0/run_route.sh $lab $PH --depths 512,8192,16384 --nctx 40960 -- $cmd > /dev/null 2>&1; local rc=$?; killall_srv
    local c=$(classify $O/$lab $rc $wd0)
    say "END $lab: $c | $(grep -h '^RESULT' $O/$lab/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+|prefill_tps=[^ ]+|decode_tps=[^ ]+' | awk '!s[$0]++' | paste -sd' ') | $(acc $O/$lab) | $(grep -aoE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+|error: [^|]{0,80}' $O/$lab/server.log | head -1)"
    case $c in
      PASS) [ $pre = probe ] || sleep 180; return 0;;
      HANG|DEVFAULT) HANGS=$((HANGS+1)); [ $HANGS -ge 3 ] && { say "STOP: 3 device faults (hangs or aborts)"; exit 5; }; ready wait; return 0;;
      LOADFAIL) mv $O/$lab $O/$lab-loadfail$attempt; [ $attempt = 2 ] && { say "SKIP $lab: failed to load twice"; return 0; }; ready wait;;
      *) if grep -q 'SERVER EXITED before ready' $O/$lab/run.txt 2>/dev/null; then mv $O/$lab $O/$lab-exit; say "SKIP $lab: server exited at load (unsupported; see server.log)"; sleep 60; return 0; fi
         say "STOP: $lab EVIDENCE"; exit 2;;
    esac; done; }
until grep -q 'fetch done' $DR/fetch.log; do sleep 60; done
grep -q MISMATCH $DR/fetch.log && { say "STOP: a draft download failed its sha256 check"; exit 6; }
while pgrep -f '^/bin/bash /home/arduino/v0/v0d_spec.sh' > /dev/null; do sleep 60; done
grep -qE 'STOP' ~/bench-runs/v0/v0d/v0d-spec-status.txt && { say "round 2 not started: round 1 stopped"; exit 7; }
say "spec round 2 start (pid $$)"; ready now
T4X="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
FAST="--spec-draft-threads 4 --cpu-mask-draft 0xF"
# 4B, base-model MTP head: faster CPU draft (repacked weights, 4 big-core threads, not strict)
run 4B-mtpbase-n1-fast none $T4 -md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 1 $CPUD $FAST
# 4B, base-model MTP head on a third NPU session: only the MTP layer (blk.32) and the output head offloaded
run 4B-mtpbase-n1-npu none $T4X -md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 1 --device-draft HTP0:2 --spec-draft-ngl all -otd 'blk\.([0-9]|[12][0-9]|3[01])\.=CPU' --no-repack
# 9B, own MTP head: MTP layer on the NPU (-ngl 34 instead of 33), then a faster CPU draft
run 9B-mtp-n1-ngl34 probe ${T9/-ngl 33/-ngl 34} --spec-type draft-mtp --spec-draft-n-max 1
run 9B-mtp-n1-fast probe $T9 --spec-type draft-mtp --spec-draft-n-max 1 $FAST
say "spec round 2 done (hangs $HANGS)"
