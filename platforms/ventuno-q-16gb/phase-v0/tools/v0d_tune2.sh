#!/bin/bash
# V0d tuning sweep, night of 2026-10-05/06 (RUNBOOK V0d step 2: one setting at a time on the shortlist).
# Base = V0c candidate A: upstream ggml-hexagon, 2 virtual sessions, --ctx-checkpoints 0, -c 40960, defaults.
# Each sweep run: run_route.sh speed at 512 and 16K (fresh server), aggregate PASS/FAIL with health and kernel barrier.
# Part A: 9B feasibility (buffer size / vmem); Part B: 4B one-at-a-time; Part C: 4B 65K window load.
# Status: ~/bench-runs/v0/v0d/status.txt. Every step: timeout + leftover-server cleanup + sync.
set -uo pipefail
ST=~/bench-runs/v0/v0d/status.txt; mkdir -p ~/bench-runs/v0/v0d
P=~/v0/hexpkg/pkg-linux; LIB=(LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib)
N4=~/v0/models/q40/NeoHorse-1-4B-q4_0-pure.gguf; O9=~/v0/models/q40/Ornith-1.0-9B-q4_0-pure.gguf
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
cleanup() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do
  say "cleanup: killing leftover server pid $pid"; kill -KILL $pid 2>/dev/null; done; sleep 5; }
# run <label> <timeout_s> <depths> <extra env...> -- <extra server args...>
run() { local lab=$1 to=$2 dep=$3; shift 3; local envs=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  local model=$N4; for a in "${envs[@]}"; do [ "$a" = MODEL9 ] && model=$O9; done
  local e2=(); for a in "${envs[@]}"; do [ "$a" != MODEL9 ] && e2+=("$a"); done
  say "START $lab"
  timeout -k 60 "$to" ~/v0/run_route.sh "$lab" v0d-tune --depths "$dep" --nctx 40960 -- \
    env "${LIB[@]}" GGML_HEXAGON_DEVICES="${DEV:-HTP0:0,HTP0:1}" "${e2[@]}" $P/bin/llama-server -m "$model" -c "${CTX:-40960}" --cache-ram "${CRAM:-8192}" -lv 4 \
    --host 127.0.0.1 --port 8080 --device "${DEV:-HTP0:0,HTP0:1}" -ngl 99 --ctx-checkpoints 0 "$@" > /dev/null 2>&1
  local rc=$?; [ $rc = 124 ] && say "TIMEOUT $lab"; cleanup
  local o=~/bench-runs/v0/v0d-tune/$lab
  say "END $lab rc=$rc | $(grep -o 'RESULT .*' $o/run.txt 2>/dev/null | tail -1) | $(grep -h '^RESULT' $o/probe.txt 2>/dev/null | grep -oE 'depth=[0-9]+ prompt_tokens=[0-9None]+ ttft=[^ ]+ prefill_tps=[^ ]+ gen_tokens=[0-9]+ decode_tps=[^ ]+' | sed -E 's/ttft=[^ ]+ //;s/gen_tokens=[0-9]+ //' | paste -sd' ' | cut -c1-200)"
  grep -qE 'ALERT (OOM|swap used)' $o/health.txt 2>/dev/null && { say "STOP: OOM or swap in $lab"; exit 9; }
  sleep 45; }
D2=HTP0:0,HTP0:1
say "v0d tune start (pid $$)"
say "v0d tune2 start (pid $$)"
# follow-up (D53): 8-bit KV cache (supported on HTP; q4_0 is not, D45) for the 65K window; cram0 repeat
run v0d-4b-kvq8 1800 512,16384 -- -ctk q8_0 -ctv q8_0 -fa on
CTX=65536 run v0d-4b-ctx65k-kvq8 2400 512,16384 -- -ctk q8_0 -ctv q8_0 -fa on
CRAM=0 run v0d-4b-cram0-r2 1800 512,16384 --
run v0d-4b-base-end2 1800 512,16384 --
say "v0d tune2 done"
