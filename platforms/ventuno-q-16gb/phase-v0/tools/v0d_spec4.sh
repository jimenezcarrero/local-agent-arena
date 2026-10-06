#!/bin/bash
# V0d speculation round 4 (D77): the board-native NPU+GPU+CPU binary (D74, ~/v0/llama.cpp/build-dl, Hexagon via shim).
# 1. Parity gate (D78): reference and combined binary interleaved twice in this session, tools/parity.py; stops the round
#    unless all four runs pass and the candidate is within +-5 % of the reference at 8K and 16K (prefill and decode).
# 2. GPU as draft device (target on the NPU): 0.8B draft, base-model MTP layer + head, DFlash.
# 3. GPU as overflow for the 9B: output head on the GPU (546 MiB, under the 1 GiB OpenCL buffer limit), then MTP with
#    its layer and head on the GPU. GPU caveat: OpenCL lockups on long prompts in V0c (D37); depths 512/8K/16K only.
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=v0d-spec4; ST=~/bench-runs/v0/v0d/$PH-status.txt; H=~/v0/hexpkg/pkg-linux/lib; B=~/v0/llama.cpp/build-dl/bin; M=~/v0/models/q40; DR=~/v0/models/drafts; O=~/bench-runs/v0/$PH
mkdir -p $O; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
P=~/v0/hexpkg/pkg-linux
BASE="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
E="env LD_LIBRARY_PATH=$B:$H ADSP_LIBRARY_PATH=$H"
T4="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $B/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
T9="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $B/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4 --no-host"
GPUD="--device-draft GPUOpenCL --spec-draft-ngl all"
while pgrep -f '^/bin/bash /home/arduino/v0/v0d_spec3.sh' > /dev/null; do sleep 60; done
say "spec round 4 start (pid $$)"; ready now
# Parity gate (D78, pre-declared): reference (Hexagon package) and candidate (combined build) interleaved, same config,
# both runs of each must PASS, candidate mean within +-5 % of the reference mean at 8K and 16K for prefill and decode.
R4="${T4/$B\/llama-server/$P/bin/llama-server}"; R4="${R4/LD_LIBRARY_PATH=$B:$H/LD_LIBRARY_PATH=$P/lib}"
for i in 1 2; do explore ref-4B-ctrl-$i none $R4; explore dl-4B-ctrl-$i none $T4; done
for l in ref-4B-ctrl-1 ref-4B-ctrl-2 dl-4B-ctrl-1 dl-4B-ctrl-2; do grep -q "END $l: PASS" $ST || { say "STOP: parity run $l did not pass"; exit 8; }; done
python3 ~/v0/parity.py $O/ref-4B-ctrl-1 $O/ref-4B-ctrl-2 $O/dl-4B-ctrl-1 $O/dl-4B-ctrl-2 > $O/parity.txt 2>&1; prc=$?
while read -r l; do say "PARITY $l"; done < $O/parity.txt
[ $prc = 0 ] || { say "STOP: combined build fails the parity gate"; exit 8; }
explore dl-4B-d08-n4-gpu none $T4 -md $DR/Qwen3.5-0.8B-Q4_0.gguf --spec-type draft-simple --spec-draft-n-max 4 $GPUD
explore dl-4B-mtpbase-n1-gpu none $T4 -md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 1 $GPUD -otd 'blk\.([0-9]|[12][0-9]|3[01])\.=CPU' --no-repack
explore dl-4B-outcpu-dflash-gpu none $T4 -ot 'output\.weight=CPU' -md $DR/Qwen3.5-4B-DFlash.Q8_0.gguf --spec-type draft-dflash --spec-draft-n-max 4 $GPUD
explore dl-9B-ctrl-outgpu probe $T9 -ot 'output\.weight=OpenCL'
explore dl-9B-mtp-n1-gpu probe $T9 -ot 'blk\.32\.=OpenCL,output\.weight=OpenCL' --spec-type draft-mtp --spec-draft-n-max 1
say "spec round 4 done (faults $(nfaults))"
