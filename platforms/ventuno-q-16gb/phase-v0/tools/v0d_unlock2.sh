#!/bin/bash
# V0d unlock tests, round 2 (D59). Round 1 showed that with -ngl 33 the 9B output layer is held on the CPU (545.8 MiB
# CPU model buffer) but the scheduler still offloads its matmul to the last HTP session ("op offload"), which maps
# that host buffer: "HTP0:2 buffer mapping failed ... size 572133376" (= 545.6 MiB) at the first graph compute.
# --no-op-offload keeps host-tensor ops on the CPU. Waits for round 1 to finish; skipped if round 1 hit an NPU hang.
set -uo pipefail
ST=~/bench-runs/v0/v0d/unlock-status.txt
while pgrep -f '/home/arduino/v0/v0d_unlock.sh' > /dev/null; do sleep 30; done
grep -q 'STOP: NPU hang' $ST && { echo "$(date -Is) round 2 skipped: round 1 hit an NPU hang" >> $ST; exit 2; }
source <(sed -n '/^ST=/,/^say "unlock tests start"/p' ~/v0/v0d_unlock.sh | grep -v '^say "unlock tests start"')
say "unlock round 2 start (pid $$)"
# 4 big-core threads for the CPU part (D55)
run 9b-2s-outcpu-nopo HTP0:0,HTP0:1        Ornith-1.0-9B-q4_0-pure.gguf 40960 -ngl 33 --no-op-offload -t 4 --cpu-mask 0xF --cpu-strict 1
run 9b-3s-outcpu-nopo HTP0:0,HTP0:1,HTP0:2 Ornith-1.0-9B-q4_0-pure.gguf 40960 -ngl 33 --no-op-offload -t 4 --cpu-mask 0xF --cpu-strict 1
run 4b-2s-outcpu-nopo HTP0:0,HTP0:1        NeoHorse-1-4B-q4_0-pure.gguf 40960 -ngl 32 --no-op-offload -t 4 --cpu-mask 0xF --cpu-strict 1
run 4b-4s-outcpu-nopo-65k HTP0:0,HTP0:1,HTP0:2,HTP0:3 NeoHorse-1-4B-q4_0-pure.gguf 65536 -ngl 32 --no-op-offload -t 4 --cpu-mask 0xF --cpu-strict 1
say "unlock round 2 done"
