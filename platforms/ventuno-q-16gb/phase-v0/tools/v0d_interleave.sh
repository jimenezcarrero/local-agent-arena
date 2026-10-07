#!/bin/bash
# V0d interleaved A vs AM comparison (D97), exploratory: the admitted sets ran one after the other (Codex review
# 2026-10-07 20:24Z), so their differences mix configuration with time. Order A AM AM A A AM (counterbalanced), each run
# 512/8K/16K/32K with the exact admitted commands and caps. Fail-closed through classify()/decide() (explore mode):
# a fault is recorded and the sequence continues after recovery, EVIDENCE stops, fault cap 3. memfloor --admit is
# recorded for every run. Not an admission set; it does not change D90.
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=v0d-interleave; ST=~/bench-runs/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; DR=~/v0/models/drafts; O=~/bench-runs/v0/$PH
mkdir -p $O; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
source ~/v0/v0d_runner.sh
A="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 7942 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
AM="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 4188 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0 -md $DR/Qwen3.5-4B-Q4_0.gguf --spec-type draft-mtp --spec-draft-n-max 1 --device-draft HTP0:2 --spec-draft-ngl all -otd blk\.([0-9]|[12][0-9]|3[01])\.=CPU --no-repack"
pgrep -f '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: NPU stall watchdog not running"; exit 6; }
pgrep -f '^/bin/bash /home/arduino/v0/monitor/health_sampler.sh' > /dev/null || { say "STOP: health sampler not running"; exit 6; }
say "interleave start (pid $$)"; ready now
for lab in A-1 AM-1 AM-2 A-2 A-3 AM-3; do
  cfg=${lab%-*}; cap=7942; cmd=$A; [ $cfg = AM ] && { cap=4188; cmd=$AM; }
  for attempt in 1 2; do
    say "START $lab (attempt $attempt)"; c=$(step_once $lab speed 512,8192,16384,32768 5400 $cmd); a=$(decide $c $attempt explore)
    say "END $lab: $c -> $a | $(summary $O/$lab)"
    case $a in
      next) python3 $MEMFLOOR --admit $cap $O/$lab > $O/$lab/memfloor-admit.txt 2>&1; say "MEM $lab: $(tail -1 $O/$lab/memfloor-admit.txt)"; sleep $SET_PAUSE; break;;
      fault) mv $O/$lab $O/$lab-fault; fault $lab $c; ready wait; break;;
      recover_retry) mv $O/$lab $O/$lab-loadfail1; ready wait;;
      skip) mv $O/$lab $O/$lab-loadfail2; say "SKIP $lab: load failed twice"; break;;
      *) say "STOP: $lab $c"; exit 2;;
    esac
  done
done
say "interleave done (faults $(nfaults))"
