#!/bin/bash
# replay_monitor.sh — re-run the per-lifetime memory, coverage and kernel audits and the probes' kernel audits on the
# committed evidence only (MONITOR_DIR=phase-v1/monitor), and compare each verdict with the one the batch recorded.
# Exit 0 when every replayed verdict matches; prints one line per check.
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; P=$(dirname "$HERE"); V0T=$P/../phase-v0/tools
export MONITOR_DIR=$P/monitor
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
bad=0
same() { if [ "$2" = "$3" ]; then echo "same      $1"; else echo "DIFFERENT $1"; echo "  recorded: $2"; echo "  replayed: $3"; bad=1; fi; }
for lt in "$P"/lifetimes/*/; do
  id=$(basename "$lt"); d=$T/$id; mkdir -p "$d"; cp "$lt/run.txt" "$d/"
  ln -s "$P/runs/$(sed 's|^arena[0-9]/||' "$lt/server-log.txt")" "$d/server.log"
  cov=$(python3 -I "$HERE/v1_coverage.py" "$d" 2>&1); rec=$(grep -oE "LIFETIME $id: pid [0-9]+, .*; ADMIT" "$P/batch/status.txt" | sed -E 's/^LIFETIME [^:]+: pid [0-9]+, //; s/; ADMIT$//')
  same "$id coverage" "$rec" "$cov"
  same "$id memory admission" "$(cat "$lt/memfloor-admit.txt")" "$(python3 -I "$V0T/memfloor.py" --admit 5120 "$d" 2>&1)"
  same "$id kernel audit" "$(cat "$lt/kernel-audit.txt")" "$(python3 -I "$V0T/kernel_audit.py" "$d" 2>&1)"
done
for p in "$P"/probes/probe-*/; do
  same "$(basename "$p") kernel audit" "$(cat "$p/kernel-audit.txt")" "$(python3 -I "$V0T/kernel_audit.py" "$p" 2>&1)"
done
[ $bad = 0 ] && echo "RESULT replay: all verdicts reproduce from the committed export" || echo "RESULT replay: DIFFERENT"
exit $bad
