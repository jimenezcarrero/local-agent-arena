#!/bin/bash
# Ventuno V0 health sampler: one JSON line every INTERVAL seconds to
# ~/bench-runs/monitor/health-<UTC date>.jsonl. Memory, swap, PSI, thermals,
# CPU clocks vs limits (throttling), cooling states, test processes, OOM/kernel errors.
# Never edit while running (OPERATING.md rule 13): write a new file and mv it over.
INTERVAL=${INTERVAL:-10}
OUT=${OUT:-$HOME/bench-runs/monitor}
mkdir -p "$OUT"
last_kmsg_check=$(date +%s)
while :; do
  now=$(date +%s)
  f="$OUT/health-$(date -u +%Y%m%d).jsonl"
  mem=$(awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree|Cached|Shmem):/{gsub(":","",$1);printf "\"%s_kB\":%s,",$1,$2}' /proc/meminfo)
  psi_m=$(awk '{for(i=2;i<=5;i++){split($i,a,"=");printf "\"mem_%s_%s\":%s,",$1,a[1],a[2]}}' /proc/pressure/memory 2>/dev/null)
  psi_c=$(awk '$1=="some"{split($2,a,"=");printf "\"cpu_some_avg10\":%s,",a[2]}' /proc/pressure/cpu 2>/dev/null)
  temps=$(for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/temp 2>/dev/null) || continue; printf '"%s":%s,' "$(cat $z/type)" "$t"; done)
  freqs=$(for p in /sys/devices/system/cpu/cpufreq/policy*; do printf '"%s":[%s,%s,%s],' "${p##*/}" "$(cat $p/scaling_cur_freq)" "$(cat $p/scaling_max_freq)" "$(cat $p/cpuinfo_max_freq)"; done)
  cool=$(for c in /sys/class/thermal/cooling_device*; do s=$(cat $c/cur_state 2>/dev/null) || continue; [ "$s" != 0 ] && printf '"%s:%s":%s,' "${c##*/}" "$(cat $c/type)" "$s"; done)
  gpu=$(cat /sys/class/kgsl/kgsl-3d0/gpuclk 2>/dev/null || echo null)
  procs=$(ps -eo pid,etimes,rss,pcpu,args --no-headers | awk '/llama-|geniex|speed_probe|probe_toolcalls|llama-quantize|convert_hf|pi-coding|bin\/pi /&&!/awk/{a=$5;for(i=6;i<=8&&i<=NF;i++)a=a" "$i;gsub(/["\\]/,"",a);printf "%s{\"pid\":%s,\"age_s\":%s,\"rss_kB\":%s,\"cpu\":%s,\"cmd\":\"%s\"}",(n++?",":""),$1,$2,$3,$4,substr(a,1,120)}')
  kern=""
  if (( now - last_kmsg_check >= 60 )); then
    kern=$(journalctl -k --since "@$last_kmsg_check" --no-pager -o cat 2>/dev/null | grep -ciE 'oom|killed process|out of memory|thermal|throttl|fastrpc.*err|kgsl.*fault|error' )
    oom=$(journalctl -k --since "@$last_kmsg_check" --no-pager -o short-iso 2>/dev/null | grep -E 'Killed process|oom-kill' | tail -3 | tr '"\\' "''" | paste -sd'|')
    kern="\"kern_alert_lines_60s\":${kern:-0},\"oom\":\"$oom\","
    last_kmsg_check=$now
  fi
  printf '{"ts":"%s","epoch":%s,%s%s%s%s"temp_mC":{%s},"freq_cur_max_hw":{%s},"cooling_active":{%s},"gpuclk":%s,"load":"%s","procs":[%s]}\n' \
    "$(date -Is)" "$now" "$mem" "$psi_m" "$psi_c" "$kern" "${temps%,}" "${freqs%,}" "${cool%,}" "$gpu" "$(cut -d' ' -f1-3 /proc/loadavg)" "$procs" >> "$f"
  sleep "$INTERVAL"
done
