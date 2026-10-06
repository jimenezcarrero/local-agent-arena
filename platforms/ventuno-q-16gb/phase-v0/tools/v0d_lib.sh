#!/bin/bash
# v0d_lib.sh — fail-closed step logic for V0d comparison/admission sequences (Codex review of #45, 2026-10-06).
# classify <run dir> <runner rc> <watchdog count before> -> prints one class, returns 0 only for PASS:
#   PASS      runner rc 0, a "RESULT PASS" line, health-verdict.txt present and starting with "pass"
#   HANG      the NPU stall watchdog fired during the step (device fault)
#   LOADFAIL  server exited before ready with an NPU "mapping failed" line (load incompatibility or degraded NPU)
#   EVIDENCE  anything else: timeout (124), runner crash, missing/garbled RESULT, missing/failed health verdict
WD_LOG=${WD_LOG:-$HOME/bench-runs/v0/night/status.txt}
wdcount() { local n; n=$(grep -c NPU-WATCHDOG "$WD_LOG" 2>/dev/null); echo "${n:-0}"; }
classify() { local d=$1 rc=$2 wd0=$3
  [ "$(wdcount)" != "$wd0" ] && { echo HANG; return 1; }
  if [ "$rc" = 0 ] && grep -q '^.* RESULT PASS' "$d/run.txt" 2>/dev/null && head -1 "$d/health-verdict.txt" 2>/dev/null | grep -q '^pass'; then
    echo PASS; return 0; fi
  if grep -q 'SERVER EXITED before ready' "$d/run.txt" 2>/dev/null && grep -q 'mapping failed' "$d/server.log" 2>/dev/null; then
    echo LOADFAIL; return 1; fi
  echo EVIDENCE; return 1; }
