#!/bin/bash
# V0b at the frozen measurement commit 7badb21: every route on Qwen2.5-1.5B pure Q4_0, depth 512.
# llama.cpp: Arduino's flags + --cache-ram 8192 (explicit default) + -lv 4 (placement lines).
# GenieX: serve --compute <unit> at its defaults, --skip-update, --log debug.
# 30 s idle gap between routes. Results: ~/bench-runs/v0/v0b-7badb21/
set -uo pipefail
P=v0b-7badb21
B=~/v0/llama.cpp; M=~/v0/models/q40/qwen2.5-1.5b-instruct-q4_0-pure.gguf
LF=(--no-warmup -b 128 -c 2048 -s 11 -n 128 --host 127.0.0.1 --port 8080 --cache-ram 8192 -lv 4)
G=http://127.0.0.1:18181; GM=qualcomm/qwen15-q40-pure:Q4_0
run_ll() { ~/v0/run_route.sh "$1" $P --depths 512 -- "$B/$2/bin/llama-server" -m "$M" "${LF[@]}" > /dev/null; echo "$1 rc=$?"; sleep 30; }
run_gx() { URL=$G HEALTH=$G/v1/models ~/v0/run_route.sh "geniex-$1-sanity" $P --depths 512 --url $G --model $GM -- \
             geniex --skip-update --log debug serve --compute "$1" > /dev/null; echo "geniex-$1 rc=$?"; sleep 30; }
echo "$(date -Is) V0b batch start"
run_ll llamacpp-opencl-sanity build-opencl
run_ll llamacpp-opencl-v82-sanity build-opencl-v82
run_ll llamacpp-cpu-sanity build-cpu
run_ll llamacpp-cpu-v82-sanity build-cpu-v82
run_gx gpu
run_gx cpu
run_gx hybrid
run_gx npu
echo "$(date -Is) V0b batch done"
