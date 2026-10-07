#!/bin/bash
# Runs the D85 admission sets in order; continues past 0 (admitted) or 3 (not eligible / memory reject), stops otherwise.
for s in A AM H; do /bin/bash /home/arduino/v0/v0d_admit.sh $s; rc=$?
  echo "$(date -Is) chain: set $s rc=$rc" >> ~/bench-runs/v0/v0d/admit-chain.txt
  case $rc in 0|3) sleep 180;; *) echo "$(date -Is) chain: STOP" >> ~/bench-runs/v0/v0d/admit-chain.txt; exit $rc;; esac
done; echo "$(date -Is) chain: done" >> ~/bench-runs/v0/v0d/admit-chain.txt
