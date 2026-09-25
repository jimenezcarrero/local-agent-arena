#!/bin/bash
# Phase A10: settle the NeoHorse sampling question. Its default-sampling arm
# stands at 11/11, 10/11 and one void run (two OOM kills landed inside it), so
# it cannot be compared with the 3/3 at vendor sampling. Three fresh marathons
# plus 32K crushers at llama.cpp defaults, with the board otherwise idle.
set -u
S=$(cd "$(dirname "$(readlink -f "$0")")/../../.." && pwd)/suite
B=/home/JetsonOrin/Repositories/llama.cpp-master/build-novmm/bin/llama-server
M=/home/JetsonOrin/Repositories/llama.cpp/models
C=(-ngl 99 -fa on -ctk q4_0 -ctv q4_0 -b 512 -ub 128 -np 1 --jinja --metrics)
export PI_PROVIDER=jetson
for r in 1 2 3; do
  STEPS="3 4s" "$S/run_model.sh" neohorse-q4-def$r 32768 0 "$B" -m "$M/NeoHorse-1-4B-Q4_K_M.gguf" "${C[@]}"
done
