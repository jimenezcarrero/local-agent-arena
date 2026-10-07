#!/bin/bash
# V0d speculation round 5 (D83): DFlash block drafting for the 4B, target on 4 NPU sessions so the n_max recurrent-state
# snapshots fit per session; DFlash draft (Qwen3.5-4B-DFlash Q8_0, 0.6B) on the CPU with 4 big-core threads.
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=v0d-spec5; ST=~/bench-runs/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; DR=~/v0/models/drafts; O=~/bench-runs/v0/$PH
mkdir -p $O; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
T44="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2,HTP0:3 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2,HTP0:3 -ngl 99 --ctx-checkpoints 0"
DF="-md $DR/Qwen3.5-4B-DFlash.Q8_0.gguf --spec-type draft-dflash --device-draft none --spec-draft-ngl 0 --spec-draft-threads 4 --spec-draft-cpu-mask 0xF"
say "spec round 5 start (pid $$)"; ready now
explore 4B-4s-ctrl none $T44
explore 4B-4s-dflash-n3 none $T44 $DF --spec-draft-n-max 3
explore 4B-4s-dflash-n7 none $T44 $DF --spec-draft-n-max 7
say "spec round 5 done (faults $(nfaults))"
