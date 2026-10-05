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
# ---- Part A: 9B feasibility on the NPU (2 sessions): smaller max buffer size; measured vmem
DEV=$D2 run v0d-9b-mbuf256 2400 512,16384 MODEL9 GGML_HEXAGON_MBUF=256 --
DEV=$D2 run v0d-9b-mbuf512 2400 512,16384 MODEL9 GGML_HEXAGON_MBUF=512 --
DEV=$D2 run v0d-9b-mbuf256-vmem0 2400 512,16384 MODEL9 GGML_HEXAGON_MBUF=256 GGML_HEXAGON_VMEM=0 --
# ---- Part B: 4B, one setting at a time from the candidate (base re-run first, same day/thermal state)
run v0d-4b-base 1800 512,16384 --
run v0d-4b-t2 1800 512,16384 -- -t 2
run v0d-4b-t4 1800 512,16384 -- -t 4
run v0d-4b-t6 1800 512,16384 -- -t 6
run v0d-4b-t4-tb8 1800 512,16384 -- -t 4 -tb 8
run v0d-4b-t4-big 1800 512,16384 -- -t 4 --cpu-mask 0xF --cpu-strict 1
run v0d-4b-ub128 1800 512,16384 -- -ub 128
run v0d-4b-ub256 1800 512,16384 -- -ub 256
run v0d-4b-oppoll1 1800 512,16384 GGML_HEXAGON_OPPOLL=1 --
CRAM=0 run v0d-4b-cram0 1800 512,16384 --
CRAM=512 run v0d-4b-cram512 1800 512,16384 --
CRAM=2048 run v0d-4b-cram2048 1800 512,16384 --
# ---- Part C: 4B at a 65K window (load + 512 only; full window qualification is V0e)
CTX=65536 run v0d-4b-ctx65k 1800 512 --
run v0d-4b-base-end 1800 512,16384 --
say "v0d tune done"
