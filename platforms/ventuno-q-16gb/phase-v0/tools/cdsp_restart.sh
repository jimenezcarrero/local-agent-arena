#!/bin/bash
# cdsp_restart.sh — installed root-owned as /usr/local/sbin/v0-cdsp-restart by tools/install_cdsp_restart.sh (D91, D92).
# Restarts the compute DSP (the NPU: remoteproc named 26300000.remoteproc) and nothing else. The arduino user may run it
# through sudo without a password and WITHOUT arguments (the sudoers rule allows none). It reads no arguments, no
# environment and no file the arduino user can write. Hardened after the Codex review of #45 (2026-10-07 21:06Z):
#   - expiry: the installer writes EXPIRES below; after it the helper refuses (owner: "only for tonight")
#   - one restart at a time: non-blocking flock on a root-only lock in /run
#   - fail closed on quiescence: refuses if any process holds /dev/fastrpc-cdsp or /dev/fastrpc-cdsp-secure open
#     (every NPU client, whatever its name), or if that cannot be established (any /proc read error)
#   - the starting state must be "running"; anything else is refused
#   - BEGIN is logged (and the log write must succeed) before the first state change; every write runs in the
#     background with its own 90 s deadline, so a write that blocks in the kernel ends the helper with UNKNOWN (exit 7)
#     instead of hanging it; a later call then refuses (state not "running") and the campaign must stop
#   - one terminal line per call: OK, FAIL, REFUSED or UNKNOWN, with states and duration
# Exit 0 only after stop -> offline -> start -> running.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
# --- constants (tools/test_cdsp_restart.sh rewrites only these lines in a copy under /tmp) ---
EXPIRES=0
NAME=26300000.remoteproc
SYS=/sys/class/remoteproc
PROC=/proc
DEVS="/dev/fastrpc-cdsp /dev/fastrpc-cdsp-secure"
LOG=/var/log/v0-cdsp-restart.log
LOCK=/run/v0-cdsp-restart.lock
NEED_UID=0
STEP_S=90
# --- end of constants ---
now() { date +%s; }
t0=$(now)
rd() { timeout 5 cat "$1" 2>/dev/null; }                   # every sysfs read is bounded too
log() { echo "$(date -Is) $*" >> "$LOG" && echo "$(date -Is) $*"; }
fin() { log "$1 ($(( $(now) - t0 )) s)"; exit "$2"; }   # terminal line; if even this write fails the exit code stands
[ "$(id -u)" = "$NEED_UID" ] || { echo "must run as root (sudo /usr/local/sbin/v0-cdsp-restart)" >&2; exit 2; }
[ $# = 0 ] || { echo "takes no arguments" >&2; exit 2; }
[ "$EXPIRES" -gt 0 ] 2>/dev/null || { echo "not configured (no expiry); install with install_cdsp_restart.sh" >&2; exit 2; }
[ "$(now)" -lt "$EXPIRES" ] || fin "REFUSED expired at $(date -d @"$EXPIRES" -Is)" 3
exec 9> "$LOCK" || fin "FAIL cannot open lock $LOCK" 3
flock -n 9 || fin "REFUSED another restart is in progress" 4
rp=""
for d in "$SYS"/remoteproc*; do [ "$(rd "$d/name")" = "$NAME" ] && rp=$d && break; done
[ -n "$rp" ] || fin "FAIL no remoteproc named $NAME" 3
# quiescence: no process may hold a cDSP FastRPC device; any unreadable /proc entry other than a vanished pid fails
holders=""
for p in "$PROC"/[0-9]*; do
  [ -d "$p/fd" ] || continue
  fds=$(ls "$p/fd" 2>/dev/null) || { [ -d "$p" ] && fin "REFUSED cannot inspect $p/fd: quiescence not established" 4; continue; }
  for f in $fds; do
    t=$(readlink "$p/fd/$f" 2>/dev/null) || continue
    for dev in $DEVS; do [ "$t" = "$dev" ] && holders="$holders ${p##*/}($(rd "$p/comm"))"; done
  done
done
[ -z "$holders" ] || fin "REFUSED cDSP clients open:$holders" 4
s0=$(rd "$rp/state") || fin "FAIL cannot read $rp/state" 3
[ "$s0" = running ] || fin "REFUSED unexpected starting state '$s0' (expected running)" 4
log "BEGIN $rp ($NAME) state $s0" > /dev/null || { echo "cannot write $LOG; nothing changed" >&2; exit 3; }
# write $1 to the state file in the background; wait up to STEP_S for the write to return and the state to become $2
step() { local cmd=$1 want=$2 w i st
  ( echo "$cmd" > "$rp/state" ) 2>/dev/null & w=$!
  for i in $(seq 1 "$STEP_S"); do
    if ! kill -0 "$w" 2>/dev/null; then
      wait "$w" || fin "FAIL write '$cmd' returned an error (state $(rd "$rp/state"))" 5
      st=$(rd "$rp/state"); [ "$st" = "$want" ] && return 0
    fi
    sleep 1
  done
  kill -0 "$w" 2>/dev/null && fin "UNKNOWN write '$cmd' still blocked after ${STEP_S}s (state $(rd "$rp/state")); stop the campaign" 7
  fin "FAIL state '$(rd "$rp/state")' after '$cmd' (expected $want)" 6; }
step stop offline
step start running
fin "OK $rp ($NAME) running -> offline -> running" 0
