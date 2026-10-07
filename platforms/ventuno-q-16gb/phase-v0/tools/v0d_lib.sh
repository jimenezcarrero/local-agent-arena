#!/bin/bash
# v0d_lib.sh — fail-closed step logic for V0d comparison/admission sequences (Codex reviews of #45, 2026-10-06).
# classify <run dir> <runner rc> <watchdog count before> -> prints one class, returns 0 only for PASS. Checked in order:
#   HANG      the NPU stall watchdog fired during the step (device fault)
#   DEVFAULT  the server aborted on an NPU runtime error after it was ready (server.log: "ggml-hex: ... failed" with an
#             abort, e.g. "dspqueue_read failed"; D71): a device fault like a hang, not a load failure
#   PASS      runner rc 0, last RESULT line "RESULT PASS", health-verdict.txt present and starting with "pass"
#   LOADFAIL  ONLY a clean load failure: runner rc 1 (completed, not timeout/crash), last RESULT line exactly
#             "RESULT FAIL: speed=4" (no health or kernel failure listed), health verdict present and passing,
#             "SERVER EXITED before ready" in run.txt and an NPU "mapping failed" line in server.log
#   Kernel audit (kernel_audit.py -> <run dir>/kernel-audit.txt, Codex review 20:32Z finding 1), independent of speed:
#             a GPU/DSP/SMMU/fastrpc fault line in the run window -> DEVFAULT; unknown alert lines or missing kernel
#             input -> EVIDENCE; PASS needs a clean audit; NPU "failed to map buffer" lines are accepted only in a
#             LOADFAIL (the history shows them in load failures only)
#   EVIDENCE  everything else: timeout (124), runner crash, missing/garbled RESULT, missing/failed health verdict,
#             failed post-end kernel read, a speed failure, or a load failure mixed with any of these
WD_LOG=${WD_LOG:-$HOME/bench-runs/v0/night/status.txt}
KAUDIT=${KAUDIT:-python3 $HOME/v0/kernel_audit.py}
wdcount() { local n; n=$(grep -c NPU-WATCHDOG "$WD_LOG" 2>/dev/null); echo "${n:-0}"; }
classify() { local d=$1 rc=$2 wd0=$3 res hv ka krc
  [ "$(wdcount)" != "$wd0" ] && { echo HANG; return 1; }
  $KAUDIT "$d" > "$d/kernel-audit.txt" 2>&1; krc=$?; ka=$(head -1 "$d/kernel-audit.txt" | cut -d' ' -f1)
  [ $krc = 1 ] && [ "$ka" = fault ] && { echo DEVFAULT; return 1; }
  { [ $krc = 0 ] && { [ "$ka" = pass ] || [ "$ka" = npu_map ]; }; } || { echo EVIDENCE; return 1; }
  if ! grep -q 'SERVER EXITED before ready' "$d/run.txt" 2>/dev/null && grep -qE 'ggml-hex: [a-z_]+ failed' "$d/server.log" 2>/dev/null \
     && grep -qE 'ggml_abort|GGML_ABORT|terminate called' "$d/server.log" 2>/dev/null; then echo DEVFAULT; return 1; fi
  res=$(grep -oE 'RESULT (PASS|FAIL).*' "$d/run.txt" 2>/dev/null | tail -1)
  hv=$(head -1 "$d/health-verdict.txt" 2>/dev/null)
  case "$hv" in pass*) hok=1;; *) hok=0;; esac
  if [ "$rc" = 0 ] && [ "${res:0:11}" = "RESULT PASS" ] && [ $hok = 1 ] && [ "$ka" = pass ]; then echo PASS; return 0; fi
  if [ "$rc" = 1 ] && [ "$res" = "RESULT FAIL: speed=4" ] && [ $hok = 1 ] \
     && grep -q 'SERVER EXITED before ready' "$d/run.txt" 2>/dev/null && grep -q 'mapping failed' "$d/server.log" 2>/dev/null; then
    echo LOADFAIL; return 1; fi
  echo EVIDENCE; return 1; }

# decide <class> <attempt> <mode: explore|admit|probe> -> one action (Codex review 14:08Z findings 2-3). Every class has an
# explicit policy; EVIDENCE always stops (no skip path for timeouts, crashes or missing/failed health or kernel evidence).
#   PASS     -> next
#   LOADFAIL -> attempt 1: recover_retry (baseline probe, then retry once); attempt 2: skip (explore: the configuration
#               does not load, recorded) | stop (admit: an admission set cannot skip a step) | retry_later (probe)
#   HANG, DEVFAULT -> fault: explore records it and moves on after recovery; admit applies the D68 set restart;
#               probe records it in the fault history and keeps probing
#   EVIDENCE or anything else -> stop
decide() { local c=$1 a=$2 m=$3
  case "$c" in
    PASS) echo next;;
    LOADFAIL) if [ "$m" = probe ]; then echo retry_later; elif [ "$a" = 1 ]; then echo recover_retry; elif [ "$m" = explore ]; then echo skip; else echo stop; fi;;
    HANG|DEVFAULT) echo fault;;
    *) echo stop;;
  esac; }
