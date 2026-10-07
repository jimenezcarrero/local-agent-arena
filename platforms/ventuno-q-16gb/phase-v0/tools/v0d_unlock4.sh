#!/bin/bash
# V0d unlock tests, round 4 (D59). Rounds 1-2: every 9B failure maps 572133376 bytes = 572129280 + 4 KiB, exactly
# the Q4_0 token_embd (248320 x 4096). token_embd always stays on the CPU, but llama.cpp allocates CPU-side weights
# in the first device's host buffer type (ggml-hexagon: rpcmem shared with the DSP), which is then mapped into an HTP
# session; --no-op-offload did not help. --no-host bypasses the host buffer (plain CPU memory, never mapped).
# For the 4B the same table is 357 MiB; freeing that mapping may let 65K fit on fewer sessions.
set -uo pipefail
ST=~/bench-runs/v0/v0d/unlock-status.txt
while pgrep -f '/home/arduino/v0/v0d_unlock[23].sh' > /dev/null; do sleep 30; done
grep -q 'STOP: NPU hang' $ST && { echo "$(date -Is) round 4 skipped: an NPU hang occurred" >> $ST; exit 2; }
source <(sed -n '/^ST=/,/^say "unlock tests start"/p' ~/v0/v0d_unlock.sh | grep -v '^say "unlock tests start"')
say "unlock round 4 start (pid $$)"
run 9b-2s-nohost       HTP0:0,HTP0:1        Ornith-1.0-9B-q4_0-pure.gguf 40960 -ngl 99 --no-host
run 9b-3s-nohost       HTP0:0,HTP0:1,HTP0:2 Ornith-1.0-9B-q4_0-pure.gguf 40960 -ngl 99 --no-host
run 4b-2s-nohost       HTP0:0,HTP0:1        NeoHorse-1-4B-q4_0-pure.gguf 40960 -ngl 99 --no-host
run 4b-2s-nohost-65k   HTP0:0,HTP0:1        NeoHorse-1-4B-q4_0-pure.gguf 65536 -ngl 99 --no-host
say "unlock round 4 done"
