#!/bin/bash
# cdsp_pre.sh (D92; D102: owner-authorized again on 2026-10-08, for the window the installed helper's expiry sets): restart the cDSP through the installed,
# expiring helper, then let its lifecycle kernel messages settle (30 s) so they fall before the next run window.
# Used only as PRE_LOAD by v0d_cdsp_test.sh and v0d_admit.sh H2. Any helper failure is returned unchanged.
sudo -n /usr/local/sbin/v0-cdsp-restart || exit $?
sleep 30; echo "$(date -Is) settled 30 s after the restart"
