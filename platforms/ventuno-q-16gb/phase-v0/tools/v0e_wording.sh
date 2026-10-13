#!/bin/bash
# v0e_wording.sh — V0e A32-3 stage S0 workload (D167, v0e-plan-A32-3.txt), run by run_v0e.sh with OUT, URL, SPID and
# LABEL set: the cache item's turn 1 with the current and the neutral wording, 8 tries each (v0e_window.py wording).
# Its stdout goes to the run's workload.txt, where the driver reads the "WORDING:" line. Exit 0 only if every request
# was complete; the counts are a result, not a check.
set -uo pipefail
WIN=${WIN:-32768}; PIM=${PIM:-local32k}
WORDING_N=8 exec python3 ~/v0/v0e_window.py wording "$OUT" "$OUT/server.log" $WIN $PIM
