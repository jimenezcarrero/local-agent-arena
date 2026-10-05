#!/bin/bash
# CPU-route thread placement (bandwidth test: 4 big cores read 25.6 GB/s, 8 threads only 12.5 GB/s).
# llama.cpp CPU ARMv8.2 build, -c 40960 --cache-ram 8192, speed at 512 and 8K, single runs (rank only).
ST=~/bench-runs/v0/v0d/cpu-status.txt; B=~/v0/llama.cpp/build-cpu-v82/bin/llama-server; M=~/v0/models/q40
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
run() { local lab=$1 model=$2; shift 2; say "START $lab"
  timeout -k 60 5400 ~/v0/run_route.sh $lab v0d-cpu --depths 512,8192 --nctx 40960 -- $B -m $M/$model -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 "$@" > /dev/null 2>&1
  local o=~/bench-runs/v0/v0d-cpu/$lab
  say "END $lab | $(grep -o 'RESULT .*' $o/run.txt | tail -1 | cut -c1-60) | $(grep -h '^RESULT' $o/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+ prompt_tokens=[0-9None]+|prefill_tps=[^ ]+|decode_tps=[^ ]+' | paste -sd' ' | cut -c1-200)"
  for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 30; }
say "cpu thread test start"
run cpu-4b-t8      NeoHorse-1-4B-q4_0-pure.gguf
run cpu-4b-t4big   NeoHorse-1-4B-q4_0-pure.gguf -t 4 --cpu-mask 0xF --cpu-strict 1
run cpu-4b-t2fast  NeoHorse-1-4B-q4_0-pure.gguf -t 2 --cpu-mask 0xC --cpu-strict 1
run cpu-9b-t8      Ornith-1.0-9B-q4_0-pure.gguf
run cpu-9b-t4big   Ornith-1.0-9B-q4_0-pure.gguf -t 4 --cpu-mask 0xF --cpu-strict 1
say "cpu thread test done"
