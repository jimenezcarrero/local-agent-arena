#!/bin/bash
# V0d unlock tests, round 3 (D59). Round 1: the 4B loads at 65536 on 4 sessions with the output layer on the CPU
# (-ngl 32), but decode drops to ~5.2 tok/s at 16K. Here: everything on the NPU (-ngl 99) with 3-4 sessions, so
# each session's KV share stays small; plus 4 sessions at 40960 to isolate the session-count cost.
set -uo pipefail
ST=~/bench-runs/v0/v0d/unlock-status.txt
while pgrep -f '/home/arduino/v0/v0d_unlock2.sh' > /dev/null; do sleep 30; done
grep -q 'STOP: NPU hang' $ST && { echo "$(date -Is) round 3 skipped: an NPU hang occurred" >> $ST; exit 2; }
source <(sed -n '/^ST=/,/^say "unlock tests start"/p' ~/v0/v0d_unlock.sh | grep -v '^say "unlock tests start"')
say "unlock round 3 start (pid $$)"
run 4b-4s-ngl99-65k HTP0:0,HTP0:1,HTP0:2,HTP0:3 NeoHorse-1-4B-q4_0-pure.gguf 65536 -ngl 99
run 4b-3s-ngl99-65k HTP0:0,HTP0:1,HTP0:2        NeoHorse-1-4B-q4_0-pure.gguf 65536 -ngl 99
run 4b-4s-ngl99-40k HTP0:0,HTP0:1,HTP0:2,HTP0:3 NeoHorse-1-4B-q4_0-pure.gguf 40960 -ngl 99
say "unlock round 3 done"
