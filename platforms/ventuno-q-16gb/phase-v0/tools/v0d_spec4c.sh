#!/bin/bash
# V0d speculation round 4c (D82): the non-GPU part of round 4b, after the GPU lockup stopped it. Was round 4b (D81): build v2 (CPU options matched, D80). Was round 4 (D77): the board-native NPU+GPU+CPU binary (D74, ~/v0/llama.cpp/build-dl, Hexagon via shim).
# 1. Parity gate (D78): reference and combined binary interleaved twice in this session, tools/parity.py; stops the round
#    unless all four runs pass and the candidate is within +-5 % of the reference at 8K and 16K (prefill and decode).
# 2. GPU as draft device (target on the NPU): 0.8B draft, base-model MTP layer + head, DFlash.
# 3. GPU as overflow for the 9B: output head on the GPU (546 MiB, under the 1 GiB OpenCL buffer limit), then MTP with
#    its layer and head on the GPU. GPU caveat: OpenCL lockups on long prompts in V0c (D37); depths 512/8K/16K only.
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=v0d-spec4c; ST=~/bench-runs/v0/v0d/$PH-status.txt; H=~/v0/hexpkg/pkg-linux/lib; B=~/v0/llama.cpp/build-dl2/bin; M=~/v0/models/q40; DR=~/v0/models/drafts; O=~/bench-runs/v0/$PH
mkdir -p $O; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
P=~/v0/hexpkg/pkg-linux
BASE="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
E="env LD_LIBRARY_PATH=$B:$H ADSP_LIBRARY_PATH=$H"
T4="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $B/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
T9="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $B/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4 --no-host"
GPUD="--device-draft GPUOpenCL --spec-draft-ngl all"
say "spec round 4c start (pid $$)"; ready now
# ---- batch-size test (D81): cost of processing n tokens in one call on the NPU (verification cost without speculation
# bookkeeping), llama-bench from the Hexagon package, baseline probe first; timeout instead of the server watchdog.
bench() { local lab=$1; shift; ready now; local wd0=$(wdcount); mkdir -p $O/$lab; say "START $lab"
  timeout -k 30 2400 env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib "$@" -p 1,2,3,4,8 -n 0 -r 3 -d 0,8192 -o md > $O/$lab/bench.md 2> $O/$lab/bench.err; local rc=$?
  killall_srv; for pid in $(pgrep -x llama-bench); do kill -KILL $pid; done
  say "END $lab rc=$rc | $(grep -cE '^\| ' $O/$lab/bench.md) table rows"; [ "$(wdcount)" != "$wd0" ] && fault $lab HANG; [ $rc = 124 ] && fault $lab TIMEOUT; sleep 60; }
bench bench-4B GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-bench -m $M/NeoHorse-1-4B-q4_0-pure.gguf -dev HTP0:0/HTP0:1 -ngl 99
bench bench-9B GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-bench -m $M/Ornith-1.0-9B-q4_0-pure.gguf -dev HTP0:0/HTP0:1/HTP0:2 -ngl 33 -nopo 1 -t 4 --no-host 1
# ---- 4B NPU-drafted MTP with room for 2 draft tokens: target on 3 sessions, draft on a 4th (Hexagon package)
P4="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2,HTP0:3 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 -ngl 99 --ctx-checkpoints 0"
MTPN="-md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --device-draft HTP0:3 --spec-draft-ngl all -otd blk\.([0-9]|[12][0-9]|3[01])\.=CPU --no-repack"
explore 4B-3s-mtpbase-n1-npu none $P4 $MTPN --spec-draft-n-max 1
explore 4B-3s-mtpbase-n2-npu none $P4 $MTPN --spec-draft-n-max 2
say "spec round 4c done (faults $(nfaults))"
