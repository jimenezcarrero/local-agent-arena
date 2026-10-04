#!/bin/bash
# V0c exploration matrix at 7badb21, every route at its defaults with -c/--nctx 40960 (llama.cpp: --cache-ram 8192
# explicit default, -lv 4). One cell = run_v0c.sh (speed 512/8K/16K/32K, VmHWM, one-shot and agentic tool probes).
# Quick-failing cells first. After each cell: health check; the batch stops on an OOM line or swap use.
set -uo pipefail
B=~/v0/llama.cpp; M=~/v0/models
N4=$M/q40/NeoHorse-1-4B-q4_0-pure.gguf; O9=$M/q40/Ornith-1.0-9B-q4_0-pure.gguf; IQ=$M/Ornith-1.0-9B-MTP-IQ3_M.gguf
LL=(-c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080)
STATUS=~/bench-runs/v0/v0c/batch-status.txt; mkdir -p ~/bench-runs/v0/v0c
gx() { # label compute model watchdog
  GENIEX_MODEL=$3 ~/v0/run_v0c.sh "$1" geniex "$4" -- geniex --skip-update --log debug serve --compute "$2" --nctx 40960 > /dev/null 2>&1
  after "$1"; }
ll() { # label build file
  ~/v0/run_v0c.sh "$1" llama 0 -- "$B/$2/bin/llama-server" -m "$3" "${LL[@]}" > /dev/null 2>&1
  after "$1"; }
after() {
  local o=~/bench-runs/v0/v0c/$1
  echo "$(date -Is) $1 $(grep -o 'END .*' $o/run.txt | tail -1) | $(grep -c 'ERROR' $o/speed.txt 2>/dev/null) speed errors | $(grep -o 'pass [0-9]*/[0-9]*' $o/toolprobe.txt 2>/dev/null | tail -1) | $(grep -oE 'agentic (PASS|FAIL)[^)]*\)' $o/toolagentic.txt 2>/dev/null | tail -1)" | tee -a $STATUS
  if grep -qE 'ALERT (OOM|swap used)' $o/health.txt; then echo "$(date -Is) STOP: OOM or swap in $1" | tee -a $STATUS; exit 9; fi
  sleep 30; }
echo "$(date -Is) V0c batch start" | tee -a $STATUS
gx geniex-npu-ornith9b       npu    qualcomm/ornith9b-q40-pure:Q4_0   0
gx geniex-hybrid-neohorse4b  hybrid qualcomm/neohorse4b-q40-pure:Q4_0 300
gx geniex-hybrid-ornith9b    hybrid qualcomm/ornith9b-q40-pure:Q4_0   300
gx geniex-cpu-neohorse4b     cpu    qualcomm/neohorse4b-q40-pure:Q4_0 0
gx geniex-gpu-neohorse4b     gpu    qualcomm/neohorse4b-q40-pure:Q4_0 0
ll llamacpp-cpu-v82-neohorse4b    build-cpu-v82 "$N4"
ll llamacpp-opencl-neohorse4b     build-opencl  "$N4"
gx geniex-cpu-ornith9b       cpu    qualcomm/ornith9b-q40-pure:Q4_0   0
gx geniex-gpu-ornith9b       gpu    qualcomm/ornith9b-q40-pure:Q4_0   0
ll llamacpp-cpu-v82-ornith9b      build-cpu-v82 "$O9"
ll llamacpp-opencl-ornith9b       build-opencl  "$O9"
ll llamacpp-cpu-v82-ornith9b-iq3m build-cpu-v82 "$IQ"
ll llamacpp-opencl-ornith9b-iq3m  build-opencl  "$IQ"
echo "$(date -Is) V0c batch done" | tee -a $STATUS
