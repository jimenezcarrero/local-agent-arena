#!/bin/bash
# start_stage.sh <J1|J2|J3|J4> — run one stage of phase J, then hand back to
# Claude Code for review before anything else runs on the board.
#
#   1. detaches itself and returns at once, so the caller (you, or a Claude
#      review session) can exit
#   2. waits until no Claude Code process is running and the desktop is off:
#      Claude's ~400MB and the desktop's ~1.4GB are part of the margin these
#      runs need
#   3. runs the stage's queue with its publisher, then commits the stage's
#      kernel-recorded OOM exposure
#   4. handoff.sh resumes the campaign's Claude Code session headless with
#      review-prompt.md. The review audits the stage, pushes review-<stage>.md
#      with a go/no-go recommendation, and stops. It never starts a stage: the
#      next one runs only when the user starts it.
#
# Every step appends a line to ~/closeout-status.txt.
set -u
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
STAGE="${1:?usage: start_stage.sh <J1|J2|J3|J4>}"
case "$STAGE" in J1|J2|J3|J4) ;; *) echo "unknown stage: $STAGE"; exit 2;; esac
note() { echo "$(date -Is) $STAGE: $*" | tee -a "$HOME/closeout-status.txt"; }

if [ "${2:-}" != --detached ]; then
  setsid nohup "$0" "$STAGE" --detached > "$HOME/closeout-$STAGE.log" 2>&1 < /dev/null &
  echo "Stage $STAGE queued: it starts once Claude Code has exited and the desktop is off."
  echo "Log ~/closeout-$STAGE.log, status ~/closeout-status.txt"
  exit 0
fi

# Wait for both: Claude Code's memory, and the desktop's (~1.4GB). Starting
# when only Claude had exited let J1 start in the gap before going headless.
note "queued; waiting for Claude Code to exit and the desktop to stop"
while pgrep -x claude >/dev/null || systemctl is-active -q graphical.target; do sleep 30; done
note "starting"
"$HERE/run_closeout.sh" "$STAGE" &
QUEUE_PID=$!
sleep 5   # the publisher checks that the queue is running
STAGE="$STAGE" "$HERE/publish_results.sh" > "$HOME/closeout-publish-$STAGE.log" 2>&1 &
PUB_PID=$!
wait "$QUEUE_PID"; RC=$?
wait "$PUB_PID"
note "queue exit=$RC; publisher finished"

# Kernel-recorded OOM exposure for exactly this stage's runs. Committed only
# now, after the publisher, so the two never touch the git index at once.
START="$(cat "${BENCH_WORK:-$HOME/bench-runs}/.phase-j-$STAGE.start" 2>/dev/null)"
if [ -n "$START" ]; then
  "$REPO/suite/tools/oom_exposure.py" "$START" > "$HERE/oom-exposure-$STAGE.txt" 2>&1
  note "oom_exposure exit=$? (non-zero: some runs not covered)"
  (cd "$REPO" && git add "$HERE/oom-exposure-$STAGE.txt" \
     && git commit -q -m "phase-j $STAGE: kernel-recorded OOM exposure" \
     && git push -q origin HEAD) || note "exposure commit/push FAILED"
else
  note "no stage start marker: the queue never started (see ~/closeout-$STAGE.log)"
fi

# Why each server restart happened (kill, memory stall, timeout), from the
# restarts.log the harness writes; the OOM audit only sees kernel kills.
if [ -n "$START" ]; then
  tags=$(DRY_RUN=1 "$HERE/run_closeout.sh" "$STAGE" | sed -nE 's/.*run_model\.sh ([^ ]+).*/\1/p')
  dirs=$(for t in $tags; do ls -d "${BENCH_WORK:-$HOME/bench-runs}"/arena*/"$t"-a* 2>/dev/null; done)
  [ -n "$dirs" ] && "$REPO/suite/tools/restart_causes.py" $dirs > "$HERE/restart-causes-$STAGE.txt" 2>&1
  (cd "$REPO" && git add "$HERE/restart-causes-$STAGE.txt" \
     && git commit -q -m "phase-j $STAGE: restart causes" && git push -q origin HEAD) \
     || note "restart-causes commit/push FAILED (or no runs)"
fi

"$HERE/handoff.sh" "$STAGE" "$RC"
