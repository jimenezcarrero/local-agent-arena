#!/bin/bash
# V0d speculation round 3 (D76) on the tested runner (tools/v0d_runner.sh: classify + decide, EVIDENCE stops, faults
# recorded and capped). Hypothesis for the 9B MTP load failure (D75): the MTP draft context maps the target's 546 MiB
# output head (one tensor, outside the 256 MiB chunks) a second time in session 2. Test: output head on the CPU
# (-ot output.weight=CPU), which also frees session space for 2-token drafts. Then the remaining D73 matrix for the 4B.
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=v0d-spec3; ST=~/bench-runs/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; DR=~/v0/models/drafts; O=~/bench-runs/v0/$PH
mkdir -p $O; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
T4="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
T4X="${T4/GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1/GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2}"
T9="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4 --no-host"
OUT="-ot output\.weight=CPU"; FAST="--spec-draft-threads 4 --spec-draft-cpu-mask 0xF"; CPUD="--device-draft none --spec-draft-ngl 0"
while pgrep -f '^/bin/bash /home/arduino/v0/dlbuild/build_dl.sh' > /dev/null; do sleep 60; done
say "spec round 3 start (pid $$)"; ready now
# ---- 9B: output head on the CPU
explore 9B-ctrl-outcpu probe $T9 $OUT
explore 9B-mtp-n1-outcpu probe $T9 $OUT --spec-type draft-mtp --spec-draft-n-max 1 $FAST
explore 9B-mtp-n1-outcpu-ngl34 probe ${T9/-ngl 33/-ngl 34} $OUT --spec-type draft-mtp --spec-draft-n-max 1
explore 9B-mtp-n2-outcpu probe $T9 $OUT --spec-type draft-mtp --spec-draft-n-max 2 $FAST
# ---- 4B: base-model MTP head, remaining placements
explore 4B-mtpbase-n1-cpufast none $T4 -md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 1 $CPUD $FAST
explore 4B-mtpbase-n1-npu none $T4X -md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 1 --device-draft HTP0:2 --spec-draft-ngl all -otd 'blk\.([0-9]|[12][0-9]|3[01])\.=CPU' --no-repack
explore 4B-outcpu-mtpbase-n2-cpufast none $T4 $OUT -md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 2 $CPUD $FAST
say "spec round 3 done (faults $(nfaults))"
