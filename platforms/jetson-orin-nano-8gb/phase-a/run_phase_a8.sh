#!/bin/bash
# Phase A8: retry the two big-window runs that could not allocate a 131K KV
# cache while other work was resident. Board should be otherwise idle here.
set -u
S=$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)/suite
B=/home/JetsonOrin/Repositories/llama.cpp-master/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
C=(-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 512 -ub 128 -np 1 --jinja --metrics
   --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0)
export PI_PROVIDER=jetson
sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
STEPS="4b" "$S/run_model.sh" ornith10-vp-big 65536 131072 "$B" -m "$M/Ornith-1.0-9B-MTP-IQ3_M.gguf" "${C[@]}"
