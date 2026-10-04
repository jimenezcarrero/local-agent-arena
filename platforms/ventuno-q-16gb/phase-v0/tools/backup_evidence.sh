#!/bin/bash
# Daily backup of V0 evidence outside the repository (phase-v0 + ~/bench-runs without model files).
# Logs OK only after both copies succeed; any failure logs FAILED with the step and exits nonzero.
set -uo pipefail
LOG=~/v0-backups/backup.log
mkdir -p ~/v0-backups || exit 1
fail() { echo "$(date -Is) FAILED: $*" >> "$LOG"; exit 1; }
command -v rsync >/dev/null || fail "rsync not installed"
SRC1=~/Repositories/local-agent-arena/platforms/ventuno-q-16gb/phase-v0/
SRC2=~/bench-runs/
[ -d "$SRC1" ] || fail "missing $SRC1"
[ -d "$SRC2" ] || fail "missing $SRC2"
d=~/v0-backups/$(date +%Y%m%d)
mkdir -p "$d" || fail "mkdir $d"
rsync -a "$SRC1" "$d/phase-v0/" 2>>"$LOG" || fail "rsync phase-v0 rc=$?"
rsync -a --exclude '*.gguf' "$SRC2" "$d/bench-runs/" 2>>"$LOG" || fail "rsync bench-runs rc=$?"
n1=$(find "$d/phase-v0" -type f | wc -l); n2=$(find "$d/bench-runs" -type f | wc -l)
echo "$(date -Is) OK backup -> $d phase-v0_files=$n1 bench-runs_files=$n2 size=$(du -sh "$d" | cut -f1)" >> "$LOG"
