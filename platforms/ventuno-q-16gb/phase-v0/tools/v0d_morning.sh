#!/bin/bash
# Morning chain (D56): after the owner's cDSP reset, run the final V0d re-measurement, then the unlock tests.
# v0d_final.sh itself probes readiness (base config load + 512) every 10 min for up to 6 h before measuring.
# The unlock tests run only if the final run ended without an NPU hang (a hang degrades the NPU until reset).
~/v0/v0d_final.sh; rc=$?
echo "$(date -Is) morning chain: v0d_final rc=$rc" >> ~/bench-runs/v0/v0d/final-status.txt
[ $rc = 0 ] && ~/v0/v0d_unlock.sh
