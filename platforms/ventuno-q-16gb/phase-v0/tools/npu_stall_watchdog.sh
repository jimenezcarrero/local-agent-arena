#!/bin/bash
# npu_stall_watchdog.sh — runs beside the night batch. A llama-server is declared hung when, for STALL_S seconds,
# at least one of its threads sits in fastrpc_wait_for_completion (waiting on the cDSP) and the whole process uses
# < 0.5 core-s per 10 s. Then: diagnosis to ~/bench-runs/v0/night/npu-stalls/<pid>-<time>.txt, SIGKILL, status line.
# An idle server waits on futexes, not FastRPC, so it never matches.
STALL_S=${STALL_S:-300}
D=~/bench-runs/v0/night/npu-stalls; mkdir -p "$D"; ST=~/bench-runs/v0/night/status.txt
declare -A since last
while :; do
  for pid in $(ps -eo pid,args | awk '$2 ~ /\/llama-server$/ {print $1}'); do
    cpu=$(awk '{print $14+$15}' /proc/$pid/stat 2>/dev/null) || continue
    nfrpc=$(cat /proc/$pid/task/*/wchan 2>/dev/null | tr '\0' '\n' | grep -c fastrpc_wait_for_completion)
    prev=${last[$pid]:-$cpu}; last[$pid]=$cpu
    if [ "$nfrpc" -gt 0 ] && [ $((cpu - prev)) -lt 50 ]; then
      since[$pid]=${since[$pid]:-$(date +%s)}
      if [ $(( $(date +%s) - ${since[$pid]} )) -ge "$STALL_S" ]; then
        f=$D/$pid-$(date +%H%M%S).txt
        { echo "# NPU stall $(date -Is): pid $pid, ${STALL_S}s with fastrpc_wait_for_completion threads and <0.5 core-s/10 s"
          tr '\0' ' ' < /proc/$pid/cmdline; echo
          for t in /proc/$pid/task/*; do echo "$(awk '{print $3}' $t/stat) $(cat $t/wchan) $(cat $t/comm)"; done | sort | uniq -c | sort -rn
          journalctl -k --since "-10min" --no-pager -o short-iso | grep -viE 'veth|docker' | tail -5; } > "$f" 2>&1
        kill -KILL "$pid"
        echo "$(date -Is) NPU-WATCHDOG killed hung llama-server pid $pid (diagnosis: $f)" >> "$ST"; sync
        unset "since[$pid]"
      fi
    else
      unset "since[$pid]"
    fi
  done
  sleep 10
done
