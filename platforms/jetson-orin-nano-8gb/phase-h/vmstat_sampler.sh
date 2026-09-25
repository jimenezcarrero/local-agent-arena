#!/bin/bash
# Every 60s: pages swapped in/out since the last sample, major faults, free RAM
# and swap. The kernel has no PSI, so this is how a stall gets lined up against
# a thrash window after the fact.
prev_in=0; prev_out=0; prev_mf=0
while :; do
  read -r in out mf < <(awk '/^pswpin /{i=$2} /^pswpout /{o=$2} /^pgmajfault /{m=$2} END{print i,o,m}' /proc/vmstat)
  avail=$(free -m | awk 'NR==2{print $7}'); sw=$(free -m | awk 'NR==3{print $2-$3}')
  [ "$prev_in" -gt 0 ] && echo "$(date +%F\ %T) swapin=$((in-prev_in)) swapout=$((out-prev_out)) majflt=$((mf-prev_mf)) avail_mb=$avail swapfree_mb=$sw"
  prev_in=$in; prev_out=$out; prev_mf=$mf
  sleep 60
done
