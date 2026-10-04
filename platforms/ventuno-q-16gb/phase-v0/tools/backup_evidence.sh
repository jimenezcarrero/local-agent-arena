#!/bin/bash
# Daily backup of V0 evidence outside the repository (phase-v0 + raw monitor logs + run dirs).
d=~/v0-backups/$(date +%Y%m%d)
mkdir -p "$d"
rsync -a ~/Repositories/local-agent-arena/platforms/ventuno-q-16gb/phase-v0/ "$d/phase-v0/"
rsync -a --exclude '*.gguf' ~/bench-runs/ "$d/bench-runs/"
echo "$(date -Is) backup -> $d $(du -sh "$d" | cut -f1)" >> ~/v0-backups/backup.log
