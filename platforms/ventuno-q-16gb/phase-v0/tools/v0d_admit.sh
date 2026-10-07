#!/bin/bash
# V0d admission sets (D68 restart rule, D85): v0d_admit.sh <A|AM|H>. One set per invocation, each its own phase dir and
# fault counter. Exit 0 admitted, 3 not eligible / memory reject, anything else = stop the chain (fail-closed).
#   A   NeoHorse-1-4B plain, 2 NPU sessions, --cache-ram 7942 (D67)
#   AM  A + base Qwen3.5-4B MTP head drafted on a 3rd NPU session, n1 (D80), --cache-ram 4188 (D85, provisional)
#   H   Ornith-1.0-9B, 3 sessions, MBUF 256, -ngl 33 --no-op-offload -t 4 --no-host, --cache-ram 5364 (D67); probe first
set -uo pipefail
source ~/v0/v0d_lib.sh
S=$1; PH=v0d-admit-$S; ST=~/bench-runs/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; DR=~/v0/models/drafts; O=~/bench-runs/v0/$PH
mkdir -p $O ~/bench-runs/v0/v0d; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
A="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
AM="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 4188 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 -md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 1 --device-draft HTP0:2 --spec-draft-ngl all -otd blk\.([0-9]|[12][0-9]|3[01])\.=CPU --no-repack"
H="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 5364 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4 --no-host"
# fail-closed preconditions: HANG detection needs the stall watchdog, kernel/health evidence needs the sampler
pgrep -f '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: NPU stall watchdog not running"; exit 6; }
pgrep -f '^/bin/bash /home/arduino/v0/monitor/health_sampler.sh' > /dev/null || { say "STOP: health sampler not running"; exit 6; }
say "admission $S start (pid $$)"; ready now
case $S in
  A)  admit_set A 7942 none $A;;
  AM) admit_set AM 4188 none $AM;;
  H)  admit_set H 5364 probe $H;;
  *) say "unknown set $S"; exit 9;;
esac; rc=$?; say "admission $S done rc=$rc (faults $(nfaults))"; exit $rc
