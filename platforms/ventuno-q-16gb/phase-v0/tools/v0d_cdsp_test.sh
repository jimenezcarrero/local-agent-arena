#!/bin/bash
# V0d cDSP-restart screen (D92), declared before it runs. 3 cycles of: cDSP restart + 30 s settle -> unchanged 4B
# baseline probe (D64: a passing baseline before every 9B load) -> H load + 512-token speed run. Each cycle starts
# right after the previous H run, the situation in which H failed to map in D90. The method is adopted for H2 only if
# all 3 H loads pass. HANG/DEVFAULT/EVIDENCE anywhere stops (recorded); a failed probe stops (not a pass).
set -uo pipefail
source ~/v0/v0d_lib.sh
PH=v0d-cdsp-test; ST=~/bench-runs/v0/v0d/$PH-status.txt; P=~/v0/hexpkg/pkg-linux; M=~/v0/models/q40; O=~/bench-runs/v0/$PH
mkdir -p $O; say() { echo "$(date -Is) $*" | tee -a $ST; sync; }
killall_srv() { for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do kill -KILL $pid; done; sleep 5; }
E="env LD_LIBRARY_PATH=$P/lib ADSP_LIBRARY_PATH=$P/lib"
BASE="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1 $P/bin/llama-server -m $M/NeoHorse-1-4B-q4_0-pure.gguf -c 40960 --cache-ram 8192 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1 -ngl 99 --ctx-checkpoints 0"
H="$E GGML_HEXAGON_DEVICES=HTP0:0,HTP0:1,HTP0:2 GGML_HEXAGON_MBUF=256 $P/bin/llama-server -m $M/Ornith-1.0-9B-q4_0-pure.gguf -c 40960 --cache-ram 5364 -lv 4 --host 127.0.0.1 --port 8080 --device HTP0:0,HTP0:1,HTP0:2 --ctx-checkpoints 0 -ngl 33 --no-op-offload -t 4 --no-host"
pgrep -f '^/bin/bash /home/arduino/v0/npu_stall_watchdog.sh' > /dev/null || { say "STOP: NPU stall watchdog not running"; exit 6; }
pgrep -f '^/bin/bash /home/arduino/v0/monitor/health_sampler.sh' > /dev/null || { say "STOP: health sampler not running"; exit 6; }
sudo -n -l /usr/local/sbin/v0-cdsp-restart > /dev/null 2>&1 || { say "STOP: cDSP restart helper not installed"; exit 6; }
run() { local lab=$1; shift; local wd0=$(wdcount); timeout -k 60 900 ~/v0/run_route.sh $lab $PH --depths 512 --nctx 40960 -- "$@" > /dev/null 2>&1; local rc=$?
  killall_srv; local c=$(classify $O/$lab $rc $wd0); echo $c > $O/$lab/class.txt
  say "END $lab: $c | $(grep -aoE 'mapping failed[^:]*: domain_id [0-9]+ size [0-9]+' $O/$lab/server.log | head -1) | kernel audit: $(head -1 $O/$lab/kernel-audit.txt)"; }
say "cDSP screen start (pid $$)"; ok=0
for i in 1 2 3; do
  /bin/bash ~/v0/cdsp_pre.sh >> $O/pre-load.txt 2>&1 || { say "STOP: restart failed: $(tail -1 $O/pre-load.txt)"; exit 2; }
  say "RESTART $(grep -E ' (OK|FAIL|REFUSED|UNKNOWN) ' $O/pre-load.txt | tail -1)"
  run probe-$i $BASE; [ "$(cat $O/probe-$i/class.txt)" = PASS ] || { say "STOP: baseline probe after restart: $(cat $O/probe-$i/class.txt)"; exit 2; }
  run H-$i $H; c=$(cat $O/H-$i/class.txt)
  case $c in PASS) ok=$((ok+1));; LOADFAIL) ;; *) say "STOP: H-$i $c"; exit 2;; esac
done
say "cDSP screen done: H loads passing after restart + baseline: $ok/3"
[ $ok = 3 ] && { say "RESULT method adopted for H2"; exit 0; }; say "RESULT method not adopted"; exit 1
