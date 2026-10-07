#!/bin/bash
# tree_rss.sh <pid> <out>: every 0.2 s, sum RSS and PSS (kB) over the process tree rooted at <pid>; record the peak.
root=$1; out=$2; peak_rss=0; peak_pss=0
while kill -0 $root 2>/dev/null; do
  pids=$(ps -e -o pid=,ppid= | awk -v r=$root 'BEGIN{t[r]=1} {p[$1]=$2} END{ch=1; while(ch){ch=0; for(k in p) if(!(k in t) && (p[k] in t)){t[k]=1; ch=1}} for(k in t) print k}')
  rss=0; pss=0; for p in $pids; do r=$(awk '/^Rss:/{print $2}' /proc/$p/smaps_rollup 2>/dev/null); s=$(awk '/^Pss:/{print $2}' /proc/$p/smaps_rollup 2>/dev/null); rss=$((rss+${r:-0})); pss=$((pss+${s:-0})); done
  [ $rss -gt $peak_rss ] && peak_rss=$rss; [ $pss -gt $peak_pss ] && peak_pss=$pss; sleep 0.2
done; echo "peak_tree_rss_kB=$peak_rss peak_tree_pss_kB=$peak_pss" > $out
