#!/bin/bash
# Ventuno V0 health sampler (v3): one JSON line every INTERVAL seconds to
# ~/bench-runs/monitor/health-<UTC date>.jsonl, plus every kernel journal line, in full, to
# ~/bench-runs/monitor/kernel-<UTC date>.jsonl (journalctl -o json, carries _BOOT_ID and
# __REALTIME_TIMESTAMP). Kernel reads use a journal cursor file, so window boundaries are exact and
# survive restarts; a failed read is recorded as kern_read="FAILED:<rc>" (never as zero events) and
# the cursor does not advance, so the next successful read covers the gap. v3: candidate cursor committed only
# after the batch is appended and synced (FAILED:append / FAILED:cursor_commit otherwise); counters that fail
# to parse are reported as kern_parse="FAILED", never as zero.
# Never edit while running (OPERATING.md rule 13): write a new file and mv it over, then restart.
INTERVAL=${INTERVAL:-10}
KERN_EVERY=${KERN_EVERY:-30}
OUT=${OUT:-$HOME/bench-runs/monitor}
CURSOR="$OUT/kernel.cursor"
ALERT_RE='oom|killed process|out of memory|thermal|throttl|fastrpc|kgsl|adsprpc|cdsp|smmu|fault|error|segfault|hung task|watchdog'
mkdir -p "$OUT"
BOOT=$(cat /proc/sys/kernel/random/boot_id)
echo "{\"ts\":\"$(date -Is)\",\"event\":\"sampler_start\",\"version\":3,\"pid\":$$,\"boot_id\":\"$BOOT\",\"interval\":$INTERVAL}" >> "$OUT/health-$(date -u +%Y%m%d).jsonl"
# Start boundary: if no cursor yet, anchor it at the newest kernel entry (older history stays in the journal).
[ -s "$CURSOR" ] || journalctl -k -n 1 -o json --no-pager --cursor-file="$CURSOR" > /dev/null 2>&1
echo "{\"ts\":\"$(date -Is)\",\"event\":\"kernel_cursor\",\"cursor\":\"$(cat "$CURSOR" 2>/dev/null | tr -d '"')\"}" >> "$OUT/health-$(date -u +%Y%m%d).jsonl"
last_kern=0
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
  if (( now - last_kern >= KERN_EVERY )); then
    kf="$OUT/kernel-$(date -u +%Y%m%d).jsonl"
    tmp=$(mktemp "$OUT/.kern.XXXXXX"); cand="$OUT/.kernel.cursor.cand"
    # Work on a candidate cursor; the real cursor advances only after the batch is safely appended.
    # A failure at any step keeps the old cursor, so the next read replays (duplicates are tolerated, loss is not).
    cp "$CURSOR" "$cand" 2>/dev/null || rm -f "$cand"
    journalctl -k -o json --no-pager --cursor-file="$cand" > "$tmp" 2> "$tmp.err"; rc=$?
    if [ $rc -ne 0 ]; then
      kern="\"kern_read\":\"FAILED:journalctl:$rc\",\"kern_err\":\"$(head -c 200 "$tmp.err" | tr '"\\\n' "'' ")\","
    else
      n=$(wc -l < "$tmp")
      alerts=$(python3 -c 'import json,re,sys
r=re.compile(sys.argv[1],re.I); a=o=0
for l in open(sys.argv[2]):
    m=str(json.loads(l).get("MESSAGE",""))
    if r.search(m): a+=1
    if re.search(r"Killed process|oom-kill|Out of memory",m): o+=1
print(a,o)' "$ALERT_RE" "$tmp" 2>"$tmp.err") || alerts=""
      if ! { [ "$n" -eq 0 ] || { cat "$tmp" >> "$kf" && sync -f "$kf"; }; }; then
        kern="\"kern_read\":\"FAILED:append\",\"kern_new_lines\":$n,"
      elif ! mv -f "$cand" "$CURSOR" 2>/dev/null && [ "$n" -gt 0 ]; then
        kern="\"kern_read\":\"FAILED:cursor_commit\",\"kern_new_lines\":$n,"   # batch kept; next read replays it
      elif [[ "$alerts" =~ ^[0-9]+\ [0-9]+$ ]]; then
        kern="\"kern_read\":\"ok\",\"kern_new_lines\":$n,\"kern_alert_lines\":${alerts% *},\"kern_oom_lines\":${alerts#* },"
      else
        kern="\"kern_read\":\"ok\",\"kern_parse\":\"FAILED\",\"kern_new_lines\":$n,\"kern_err\":\"$(head -c 200 "$tmp.err" | tr '"\\\n' "'' ")\","
      fi
    fi
    rm -f "$cand"
    rm -f "$tmp" "$tmp.err"
    last_kern=$now
  fi
  printf '{"ts":"%s","epoch":%s,"boot_id":"%s",%s%s%s%s"temp_mC":{%s},"freq_cur_max_hw":{%s},"cooling_active":{%s},"gpuclk":%s,"load":"%s","procs":[%s]}\n' \
    "$(date -Is)" "$now" "$BOOT" "$mem" "$psi_m" "$psi_c" "$kern" "${temps%,}" "${freqs%,}" "${cool%,}" "$gpu" "$(cut -d' ' -f1-3 /proc/loadavg)" "$procs" >> "$f"
  sleep "$INTERVAL"
done
