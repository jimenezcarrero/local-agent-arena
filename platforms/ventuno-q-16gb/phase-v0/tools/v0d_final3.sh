#!/bin/bash
# V0d final re-measurement with per-configuration --cache-ram (D65, exact values D67): A at 7942 MiB, then 9B H at 5364 MiB.
# Each: discarded warm-up, r1-r3 at 512/8K/16K/32K, both tool gates. Fail-closed (tools/v0d_lib.sh): HANG or EVIDENCE
# stops; LOADFAIL -> baseline readiness probe (every 15 min, up to 3 h) then one retry. A 9B load is always preceded by a
# passing baseline probe (D64). After every PASS: memory criterion L_min >= --cache-ram + 0.33 GiB, else stop.
set -uo pipefail
source ~/v0/v0d_lib.sh
ST=~/bench-runs/v0/v0d/${PH:-v0d-final4}-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; PH=${PH:-v0d-final4}; O=~/bench-runs/v0/$PH
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
A="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
H="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 5364 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
ready() { local first=${1:-wait}; for i in $(seq 1 13); do [ $i = 1 ] && [ $first = now ] || sleep 900
    local lab=probe-$(date +%H%M%S) wd0=$(wdcount)
    timeout -k 60 900 ~/v0/run_route.sh $lab $PH --depths 512 --nctx 40960 -- $BASE > /dev/null 2>&1; local rc=$?; killall_srv
    local c=$(classify $O/$lab $rc $wd0); say "PROBE $lab: $c"
    case $c in PASS) sleep 180; return 0;; HANG|EVIDENCE) say "STOP: probe $c"; exit 2;; esac; done
  say "STOP: NPU not ready after 3 h"; exit 1; }
memok() { local d=$1 cap=$2 out; out=$(python3 ~/v0/memfloor.py --admit $cap $d | tail -1)
  if python3 ~/v0/memfloor.py --admit $cap $d > /dev/null; then say "MEM $(basename $d): $out"; return 0; fi
  say "STOP: MEM $(basename $d): $out"; exit 3; }
step() { local lab=$1 kind=$2 cmd=$3 cap=$4 pre=$5
  for attempt in 1 2; do [ $pre = probe ] && ready now
    say "START $lab (attempt $attempt)"; local wd0=$(wdcount) rc
    if [ $kind = speed ]; then timeout -k 60 5400 ~/v0/run_route.sh $lab $PH --depths 512,8192,16384,32768 --nctx 40960 -- $cmd > /dev/null 2>&1; rc=$?
    else PHASE=$PH timeout -k 60 9000 ~/v0/run_v0c.sh $lab llama 0 -- $cmd > /dev/null 2>&1; rc=$?; fi
    killall_srv; local c=$(classify $O/$lab $rc $wd0)
    say "END $lab: $c rc=$rc | $(grep -o 'RESULT .*' $O/$lab/run.txt | tail -1 | cut -c1-90)"
    case $c in
      PASS) memok $O/$lab $cap; [ $pre = probe ] || sleep 180; return 0;;
      LOADFAIL) [ $attempt = 1 ] || { say "STOP: $lab failed to load twice"; exit 4; }; mv $O/$lab $O/$lab-loadfail1; ready wait;;
      *) say "STOP: $lab $c"; exit 2;;
    esac; done; }
say "final3 start (pid $$)"
ready now
for t in warmup r1 r2 r3; do step A-$t speed "$A" 7942 none; done
step A-tools tools "$A" 7942 none
for t in warmup r1 r2 r3; do step H-$t speed "$H" 5364 probe; done
step H-tools tools "$H" 5364 probe
say "final3 done"
