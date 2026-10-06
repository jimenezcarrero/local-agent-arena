#!/bin/bash
# V0d hang diagnosis (D68, owner-approved "diagnose first"). Hypothesis: NPU hangs follow prompt-state traffic
# between HTP memory and the host (slot switches and prompt-cache saves). Arms, 4B A base (2 sessions, -ngl 99,
# --ctx-checkpoints 0, -c 40960):
#   S4C  default 4 slots, --cache-ram 7942 (the admission value)
#   S1C  -np 1, --cache-ram 7942      (no slot switching; cache saves on prompt change remain)
#   S4N  4 slots, --cache-ram 0       (slot switching, no prompt-cache saves; known slower prefill, D53/D59)
# 4 fresh loads per arm, interleaved; each load sends 5 requests (512, 8K, 16K, 8K, 512, plus any sizing retries).
# Fail-closed (tools/v0d_lib.sh): EVIDENCE stops; LOADFAIL waits for a baseline probe and retries once; HANG is the
# measured outcome here: record it, wait for a passing baseline probe (every 15 min, up to 3 h), continue.
# Pre-declared reading (before any run): an arm "reduces hangs" only if it has 0 hangs while S4C has >= 1; any other
# outcome is inconclusive at this sample size and admission keeps the default slots and cache (A 7942 MiB).
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=v0d-diag; ST=~/bench-runs/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=~/bench-runs/v0/$PH
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1"
base() { echo "$E $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 $*"; }
BASE=$(base --cache-ram 8192)
declare -A CMD=([S4C]="$(base --cache-ram 7942)" [S1C]="$(base -np 1 --cache-ram 7942)" [S4N]="$(base --cache-ram 0)")
declare -A HANGS=([S4C]=0 [S1C]=0 [S4N]=0) LOADS=([S4C]=0 [S1C]=0 [S4N]=0)
ready() { for i in $(seq 1 13); do [ $i = 1 ] && [ "${1:-wait}" = now ] || sleep 900
    local lab=probe-$(date +%H%M%S) wd0=$(wdcount)
    timeout -k 60 900 ~/v0/run_route.sh $lab $PH --depths 512 --nctx 40960 -- $BASE > /dev/null 2>&1; local rc=$?; killall_srv
    local c=$(classify $O/$lab $rc $wd0); say "PROBE $lab: $c"
    case $c in PASS) sleep 180; return 0;; HANG|EVIDENCE) say "STOP: probe $c"; exit 2;; esac; done
  say "STOP: NPU not ready after 3 h"; exit 1; }
say "diag start (pid $$)"; ready now
for i in 1 2 3 4; do for arm in S4C S1C S4N; do lab=$arm-$i
  for attempt in 1 2; do say "START $lab (attempt $attempt)"; wd0=$(wdcount)
    timeout -k 60 3600 ~/v0/run_route.sh $lab $PH --depths 512,8192,16384,8192,512 --nctx 40960 -- ${CMD[$arm]} > /dev/null 2>&1; rc=$?; killall_srv
    c=$(classify $O/$lab $rc $wd0); say "END $lab: $c rc=$rc | $(grep -o 'RESULT .*' $O/$lab/run.txt | tail -1 | cut -c1-80)"
    case $c in
      PASS) LOADS[$arm]=$((LOADS[$arm]+1)); sleep 180; break;;
      HANG) LOADS[$arm]=$((LOADS[$arm]+1)); HANGS[$arm]=$((HANGS[$arm]+1)); say "HANG count: S4C ${HANGS[S4C]}/${LOADS[S4C]} S1C ${HANGS[S1C]}/${LOADS[S1C]} S4N ${HANGS[S4N]}/${LOADS[S4N]}"; ready wait; break;;
      LOADFAIL) [ $attempt = 1 ] || { say "STOP: $lab failed to load twice"; exit 4; }; mv $O/$lab $O/$lab-loadfail1; ready wait;;
      *) say "STOP: $lab $c"; exit 2;;
    esac; done; done; done
say "diag done | hangs/loads: S4C ${HANGS[S4C]}/${LOADS[S4C]} S1C ${HANGS[S1C]}/${LOADS[S1C]} S4N ${HANGS[S4N]}/${LOADS[S4N]}"
