#!/bin/bash
# cdsp_restart.sh — installed root-owned as /usr/local/sbin/v0-cdsp-restart (tools/install_cdsp_restart.sh, D91).
# Restarts the compute DSP (the NPU, remoteproc "26300000.remoteproc") and nothing else, so a 9B load starts from a
# freshly booted cDSP. The arduino user may run it through sudo without a password and WITHOUT arguments (the sudoers
# rule allows no arguments); it reads no input, no environment and no file the arduino user can write.
# Refuses while any llama-server or llama-bench runs (they hold FastRPC sessions). Stop, wait for "offline", start,
# wait for "running"; each wait times out after 60 s. One line per restart is appended to /var/log/v0-cdsp-restart.log
# and printed. Exit 0 only if the cDSP reports "running" afterwards.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
NAME=26300000.remoteproc
LOG=/var/log/v0-cdsp-restart.log
say() { echo "$(date -Is) $*" | tee -a "$LOG"; }
[ "$(id -u)" = 0 ] || { echo "must run as root (sudo /usr/local/sbin/v0-cdsp-restart)" >&2; exit 2; }
[ $# = 0 ] || { echo "takes no arguments" >&2; exit 2; }
rp=""
for d in /sys/class/remoteproc/remoteproc*; do
  [ "$(cat "$d/name" 2>/dev/null)" = "$NAME" ] && rp=$d && break
done
[ -n "$rp" ] || { say "FAIL no remoteproc named $NAME"; exit 3; }
if pgrep -x llama-server > /dev/null || pgrep -x llama-bench > /dev/null; then say "REFUSED llama process running"; exit 4; fi
s0=$(cat "$rp/state")
waitfor() { local want=$1 i; for i in $(seq 1 60); do [ "$(cat "$rp/state")" = "$want" ] && return 0; sleep 1; done; return 1; }
t0=$(date +%s.%N)
if [ "$s0" = running ]; then
  echo stop > "$rp/state" 2>/dev/null; waitfor offline || { say "FAIL $rp stop: state $(cat "$rp/state") (was $s0)"; exit 5; }
fi
echo start > "$rp/state" 2>/dev/null; waitfor running || { say "FAIL $rp start: state $(cat "$rp/state") (was $s0)"; exit 6; }
say "OK $rp ($NAME) $s0 -> running in $(awk -v a="$t0" -v b="$(date +%s.%N)" "BEGIN{printf \"%.1f\", b-a}") s"
