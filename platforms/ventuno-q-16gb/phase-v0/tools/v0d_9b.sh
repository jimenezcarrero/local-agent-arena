#!/bin/bash
# V0d round 5 (D59): the 9B unlock and the 4B 65K depth check.
# Unlock found in rounds 1-4: Ornith-1.0-9B pure Q4_0 on 3 HTP sessions with -ngl 33 (32 repeating layers + output
# layer on the NPU; the unused MTP layer and token_embd on the CPU) and --no-op-offload (keeps the token_embd lookup
# on the CPU so its 546 MiB host buffer is never mapped into a session). Single run 16K: 152.2/5.47 (with 4 big-core
# threads). Steps:
#  1. G (same, llama.cpp default threads, no affinity) single run at 512/16K: choose G unless its 16K decode is >3 %
#     below G' (the 4-big-core variant). Affinity is avoided by default after the F hang (D57).
#  2. 4B on 4 sessions at -c 65536 (-ngl 99): depth check 512/32K/49152 (window qualification itself is V0e).
#  3. 9B final re-measurement on the chosen config: discarded warm-up + r1-r3 at 512/8K/16K/32K, then both tool gates.
# Any NPU hang stops the script.
set -uo pipefail
ST=~/bench-runs/v0/v0d/9b-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=~/bench-runs/v0/v0d-final-9b
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
cleanup() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do say "cleanup: killing leftover server $pid"; kill -KILL $pid; done; sleep 30; }
WD0=$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)
hung() { [ "$(grep -c NPU-WATCHDOG ~/bench-runs/v0/night/status.txt 2>/dev/null)" != "$WD0" ]; }
srv9() { echo env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 \
  $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 \
  --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload "$@"; }
res() { grep -h '^RESULT' $1/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+ prompt_tokens=[0-9None]+|prefill_tps=[^ ]+|decode_tps=[^ ]+' | awk '!s[$0]++' | paste -sd' ' | cut -c1-260; }
step() { local lab=$1 dep=$2 to=$3; shift 3; say "START $lab"
  timeout -k 60 $to ~/v0/run_route.sh $lab v0d-final-9b --depths $dep --nctx 40960 -- "$@" > /dev/null 2>&1
  say "END $lab | $(grep -o 'RESULT .*' $O/$lab/run.txt | tail -1 | cut -c1-70) | $(res $O/$lab) | $(grep -oE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+' $O/$lab/server.log | head -1)"
  cleanup; hung && { say "STOP: NPU hang in $lab"; exit 2; }; }
say "round 5 start (pid $$)"
step 9b-G-select 512,16384 2400 $(srv9)
G=$(grep -h '^RESULT' $O/9b-G-select/probe.txt 2>/dev/null | grep 'depth=16384' | grep -oE 'decode_tps=[0-9.]+' | head -1 | cut -d= -f2)
if grep -q 'RESULT PASS' $O/9b-G-select/run.txt && python3 -c "import sys; sys.exit(0 if float('${G:-0}') >= 0.97*5.47 else 1)"; then
  CH=G; SRV=$(srv9); else CH=Gbig; SRV=$(srv9 -t 4 --cpu-mask 0xF --cpu-strict 1); fi
say "9B config chosen: $CH (G 16K decode ${G:-n/a} vs G' 5.47)"
step 4b-4s-65k-depth 512,32768,49152 3600 env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2,HTP0:3 \
  GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 65536 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 \
  --device HTP0:0,HTP0:1,HTP0:2,HTP0:3 --ctx-checkpoints 0 -ngl 99
for t in warmup r1 r2 r3; do step 9b-$CH-$t 512,8192,16384,32768 5400 $SRV; done
say "TOOLS 9b-$CH"
PHASE=v0d-final-9b timeout -k 60 9000 ~/v0/run_v0c.sh 9b-$CH-tools llama 0 -- $SRV > /dev/null 2>&1
say "TOOLS 9b-$CH: $(grep -o 'RESULT .*' $O/9b-$CH-tools/run.txt | tail -1 | cut -c1-140)"; cleanup
hung && { say "STOP: NPU hang in tools"; exit 2; }
say "round 5 done"
