#!/bin/bash
# Phase A9: Ornith-1.0, vendor sampling vs llama.cpp defaults, at a 32K window.
# A7 tried this at 65K and the kernel OOM-killed the server six times (see
# notes.md), so those runs are void. At 32K the model fits with a desktop
# session resident, and both arms run under identical conditions — which is
# what the comparison needs. Marathon + 32K crusher, three runs per arm.
set -u
S=$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)/suite
B=/home/JetsonOrin/Repositories/llama.cpp-master/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
BASE=(-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 512 -ub 128 -np 1 --jinja --metrics)
VENDOR=("${BASE[@]}" --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0)
export PI_PROVIDER=jetson

for r in 1 2 3; do
  STEPS="3 4s" "$S/run_model.sh" ornith10-32k-def$r 32768 0 "$B" -m "$M/Ornith-1.0-9B-MTP-IQ3_M.gguf" "${BASE[@]}"
  STEPS="3 4s" "$S/run_model.sh" ornith10-32k-vp$r  32768 0 "$B" -m "$M/Ornith-1.0-9B-MTP-IQ3_M.gguf" "${VENDOR[@]}"
done
