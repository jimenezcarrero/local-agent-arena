#!/bin/bash
# v1_replay_monitor.sh <record root> <phase-v0 tools dir> (v1-plan-4B.txt section 4.4): replay_monitor.sh, B9's (D186),
# with both roots required: re-run every lifetime's coverage, memory admission and kernel audit and the probes' kernel
# audits on the record's committed monitor export only (MONITOR_DIR=<record>/monitor), and compare each verdict with
# the one the batch recorded. The record is a committed phase-v1 layout: lifetimes/, probes/, batch/status.txt,
# monitor/, runs/. Its configuration comes from its directory name (b4, a32; phase-v1 itself is B9's record), and every
# lifetime and status START line must carry that configuration's tag stem.
# Exit 0 when every replayed verdict matches; 1 when one differs; 2 (nothing replayed) on a missing or foreign input,
# never falling back to another record.
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
refuse() { echo "v1_replay_monitor: REFUSED: $*" >&2; exit 2; }
[ $# = 2 ] || refuse "usage: v1_replay_monitor.sh <record root> <phase-v0 tools dir>"
P=$(readlink -f "$1" 2>/dev/null) && [ -d "$P" ] || refuse "no record at '$1'"
V0T=$(readlink -f "$2" 2>/dev/null) && [ -f "$V0T/memfloor.py" ] && [ -f "$V0T/kernel_audit.py" ] || refuse "no memfloor.py and kernel_audit.py in '$2'"
case $(basename "$P") in b4) STEM=b4-q20-htp1;; a32) STEM=nh4-q40-a32;; phase-v1) STEM=b9-q20-htp2;;
  *) refuse "unknown record '$(basename "$P")' (b4, a32 or phase-v1)";; esac
ls "$P"/lifetimes/*/run.txt > /dev/null 2>&1 || refuse "no lifetimes in $P"
[ -s "$P/batch/status.txt" ] || refuse "no batch/status.txt in $P"
ls "$P"/monitor/health-*-runs.jsonl > /dev/null 2>&1 && ls "$P"/monitor/kernel-*.jsonl > /dev/null 2>&1 || refuse "no monitor export in $P/monitor"
[ -d "$P/runs" ] || refuse "no runs/ in $P"
for lt in "$P"/lifetimes/*/; do case $(basename "$lt") in "$STEM"-*) ;; *) refuse "lifetime $(basename "$lt") is not $STEM's";; esac; done
x=$(grep -oE ' START [a-z0-9-]+-r[0-9]+ ' "$P/batch/status.txt" | grep -v " START $STEM-r" | head -1)
[ -z "$x" ] || refuse "status.txt names another configuration:$x"
export MONITOR_DIR=$P/monitor
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
bad=0
same() { if [ "$2" = "$3" ]; then echo "same      $1"; else echo "DIFFERENT $1"; echo "  recorded: $2"; echo "  replayed: $3"; bad=1; fi; }
for lt in "$P"/lifetimes/*/; do
  id=$(basename "$lt"); d=$T/$id; mkdir -p "$d"; cp "$lt/run.txt" "$d/"
  lg=$P/runs/$(sed 's|^arena[0-9]/||' "$lt/server-log.txt" 2>/dev/null); [ -f "$lg" ] || refuse "$id: its server log is not in runs/"
  ln -s "$lg" "$d/server.log"
  cov=$(python3 -I "$HERE/v1_coverage.py" "$d" 2>&1); rec=$(grep -oE "LIFETIME $id: pid [0-9]+, .*; ADMIT" "$P/batch/status.txt" | sed -E 's/^LIFETIME [^:]+: pid [0-9]+, //; s/; ADMIT$//')
  same "$id coverage" "$rec" "$cov"
  same "$id memory admission" "$(cat "$lt/memfloor-admit.txt")" "$(python3 -I "$V0T/memfloor.py" --admit 5120 "$d" 2>&1)"
  same "$id kernel audit" "$(cat "$lt/kernel-audit.txt")" "$(python3 -I "$V0T/kernel_audit.py" "$d" 2>&1)"
done
for p in "$P"/probes/probe-*/; do
  [ -d "$p" ] || continue
  same "$(basename "$p") kernel audit" "$(cat "$p/kernel-audit.txt")" "$(python3 -I "$V0T/kernel_audit.py" "$p" 2>&1)"
done
[ $bad = 0 ] && echo "RESULT replay: all verdicts reproduce from the committed export" || echo "RESULT replay: DIFFERENT"
exit $bad
