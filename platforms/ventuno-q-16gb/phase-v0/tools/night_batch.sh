#!/bin/bash
# Night of 2026-10-04/05, unattended. Safe cells only (OpenCL and GenieX GPU x 9B deferred: GPU lockup / board-stop
# risk with nobody to power-cycle). Every step has a timeout, a cleanup of leftover servers and a sync.
# Status: ~/bench-runs/v0/night/status.txt
set -uo pipefail
ST=~/bench-runs/v0/night/status.txt; mkdir -p ~/bench-runs/v0/night
P=~/v0/hexpkg/pkg-linux; ENV=(env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib)
M=~/v0/models; N4=$M/q40/NeoHorse-1-4B-q4_0-pure.gguf; O9=$M/q40/Ornith-1.0-9B-q4_0-pure.gguf; IQ=$M/Ornith-1.0-9B-MTP-IQ3_M.gguf
COMMON=(-c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080)
say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
cleanup() {  # any leftover server from a timed-out step, matched by its executable path
  for pid in $(ps -eo pid,args | awk '$2 ~ /\/(llama-server|geniex)$/ || ($2=="env" && $0 ~ /llama-server/) {print $1}'); do
    say "cleanup: killing leftover server pid $pid ($(ps -o args= -p $pid | cut -c1-80))"; kill -KILL $pid 2>/dev/null; done; sleep 5; }
cell() {  # phase label timeout_s -- server...
  local ph=$1 lab=$2 to=$3; shift 4
  say "START $ph/$lab"
  PHASE=$ph timeout -k 60 "$to" ~/v0/run_v0c.sh "$lab" llama 0 -- "$@" > /dev/null 2>&1; local rc=$?
  [ $rc = 124 ] && say "TIMEOUT $ph/$lab after ${to}s"
  cleanup
  local o=~/bench-runs/v0/$ph/$lab
  say "END $ph/$lab rc=$rc | $(grep -o 'END .*' $o/run.txt 2>/dev/null | tail -1) | $(grep -oE 'pass [0-9]+/[0-9]+' $o/toolprobe.txt 2>/dev/null | tail -1) | $(grep -oE 'agentic (PASS|FAIL)' $o/toolagentic.txt 2>/dev/null | tail -1)"
  if grep -qE 'ALERT (OOM|swap used)' $o/health.txt 2>/dev/null; then say "STOP: OOM or swap in $lab"; exit 9; fi
  sleep 60; }
HEX2=("${ENV[@]}" GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server)
HEX3=("${ENV[@]}" GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 $P/bin/llama-server)
D2=(--device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0); D3=(--device HTP0:0,HTP0:1,HTP0:2 -ngl 99 --ctx-checkpoints 0)

say "night batch start (pid $$)"
# 1. V0c: parity file on the NPU (placement), then the CPU fallback row for the 9B files
cell v0c llamacpp-hexagon2s-ctxcp0-ornith9b-iq3m 5400 "${HEX2[@]}" -m "$IQ" "${COMMON[@]}" "${D2[@]}"
cell v0c llamacpp-cpu-v82-ornith9b       10800 ~/v0/llama.cpp/build-cpu-v82/bin/llama-server -m "$O9" "${COMMON[@]}"
cell v0c llamacpp-cpu-v82-ornith9b-iq3m  10800 ~/v0/llama.cpp/build-cpu-v82/bin/llama-server -m "$IQ" "${COMMON[@]}"
# 2. "most performant way" for the 4B on the NPU (exploratory variants of the V0c candidate, full cells)
cell v0-explore llamacpp-hexagon3s-ctxcp0-neohorse4b      5400 "${HEX3[@]}" -m "$N4" "${COMMON[@]}" "${D3[@]}"
cell v0-explore llamacpp-hexagon2s-ctxcp0-ub1024-neohorse4b 5400 "${HEX2[@]}" -m "$N4" "${COMMON[@]}" "${D2[@]}" -ub 1024
# 3. pick best and runner-up by the runbook rule (eligible: 16K prompt within +-20%, prefill >= 145, decode >= 4.4,
#    one-shot 10/10, agentic PASS; rank by 16K prefill, within 10% the higher decode)
pick=$(python3 - <<'PY'
import re, os
cands = {"A": "v0c/llamacpp-hexagon2s-ctxcp0-neohorse4b",
         "B": "v0-explore/llamacpp-hexagon3s-ctxcp0-neohorse4b",
         "C": "v0-explore/llamacpp-hexagon2s-ctxcp0-ub1024-neohorse4b"}
ok = []
for k, d in cands.items():
    d = os.path.expanduser("~/bench-runs/v0/" + d)
    try:
        sp = open(d + "/speed.txt").read(); tp = open(d + "/toolprobe.txt").read(); ag = open(d + "/toolagentic.txt").read()
    except OSError:
        continue
    m = re.search(r"RESULT [^:]+: depth=16384 prompt_tokens=(\d+) ttft=\S+ prefill_tps=([\d.]+) gen_tokens=\d+ decode_tps=([\d.]+)", sp)
    if not m or "ERROR" in m.group(0): continue
    pt, pf, dc = int(m.group(1)), float(m.group(2)), float(m.group(3))
    if 0.8*16384 <= pt <= 1.2*16384 and pf >= 145 and dc >= 4.4 and "pass 10/10" in tp and "agentic PASS" in ag:
        ok.append((pf, dc, k))
ok.sort(reverse=True)
if not ok: print("NONE"); raise SystemExit
top = ok[0][0]; near = [x for x in ok if x[0] >= 0.9 * top]; near.sort(key=lambda x: -x[1])
order = [near[0]] + [x for x in ok if x != near[0]]
print(" ".join(x[2] for x in order[:2]), "|", " ".join(f"{x[2]}:{x[0]}/{x[1]}" for x in ok))
PY
)
say "ranking (eligible, best first | prefill/decode at 16K): $pick"
read -r first second _ <<< "${pick%%|*}"
args_for() { case $1 in
  A) echo "2s";; B) echo "3s";; C) echo "2s-ub1024";; esac; }
srv() { case $1 in
  A) echo "${HEX2[*]} -m $N4 ${COMMON[*]} ${D2[*]}";;
  B) echo "${HEX3[*]} -m $N4 ${COMMON[*]} ${D3[*]}";;
  C) echo "${HEX2[*]} -m $N4 ${COMMON[*]} ${D2[*]} -ub 1024";; esac; }
# 4. repeats: one discarded warm-up per configuration, then 3 interleaved repeats, all four depths
if [ "$first" != NONE ] && [ -n "$first" ]; then
  cfgs=("$first"); [ -n "${second:-}" ] && cfgs+=("$second")
  rep() { local c=$1 tag=$2; say "REPEAT $c($(args_for $c)) $tag"
    timeout -k 60 7200 ~/v0/run_route.sh "neohorse4b-npu-$(args_for $c)-$tag" v0c-repeats --depths 512,8192,16384,32768 --nctx 40960 -- $(srv $c) > /dev/null 2>&1
    say "REPEAT $c $tag rc=$?"; cleanup; sleep 60; }
  for c in "${cfgs[@]}"; do rep $c warmup; done
  for r in 1 2 3; do for c in "${cfgs[@]}"; do rep $c r$r; done; done
fi
say "night batch done"
