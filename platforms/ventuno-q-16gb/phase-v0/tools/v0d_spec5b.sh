#!/bin/bash
# V0d speculation round 5b (D84): DFlash shares the target token_embd and output head; on 4 sessions the draft (CPU) aborted
# because token_embd sat in an HTP host buffer (D84). Retry: (a) draft on CPU with --no-host and the head on the CPU;
# (b) target on 3 sessions + --no-host, draft on the 4th NPU session. Was round 5 (D83): DFlash block drafting for the 4B, target on 4 NPU sessions so the n_max recurrent-state
# snapshots fit per session; DFlash draft (Qwen3.5-4B-DFlash Q8_0, 0.6B) on the CPU with 4 big-core threads.
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=v0d-spec5b; ST=~/bench-runs/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; DR=~/v0/models/drafts; O=~/bench-runs/v0/$PH
mkdir -p $O; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
T44="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2,HTP0:3 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 2048 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2,HTP0:3 -ngl 99 --ctx-checkpoints 0"
DF="-md $DR/Qwen3.5-4B-DFlash.Q8_0.gguf --spec-type draft-dflash --device-draft none --spec-draft-ngl 0 --spec-draft-threads 4 --spec-draft-cpu-mask 0xF"
say "spec round 5b start (pid $$)"; ready now
T43N="${T44/--device HTP0:0,HTP0:1,HTP0:2,HTP0:3/--device HTP0:0,HTP0:1,HTP0:2} --no-host"
DFN="-md $DR/Qwen3.5-4B-DFlash.Q8_0.gguf --spec-type draft-dflash --device-draft HTP0:3 --spec-draft-ngl all"
explore 4B-4s-dflash-n3-cpu none $T44 --no-host -ot output\.weight=CPU $DF --spec-draft-n-max 3
explore 4B-3s-dflash-n3-npu none $T43N $DFN --spec-draft-n-max 3
say "spec round 5b done (faults $(nfaults))"
