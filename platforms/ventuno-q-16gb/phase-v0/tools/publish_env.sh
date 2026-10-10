#!/bin/bash
# publish_env.sh <phase-v0 dir> (D121) — package provenance for publication, no root needed:
#   env/dpkg-baseline-*.txt   every dpkg baseline the health check has used (~/bench-runs/monitor), "<pkg> <version>"
#                             per line; the current one as dpkg-baseline-current.txt
#   env/apt-holds-<date>.txt  apt-mark showhold at export time
#   env/apt-history.txt       /var/log/apt/history.log(.N.gz) entries from 2026-10-04 on, keeping only Start-Date,
#                             Commandline, Install/Upgrade/Remove/Purge/Downgrade and End-Date lines (no Requested-By)
#   env/manifest.txt          line counts and sha256 of every file above
set -euo pipefail
D=$1/env; M=~/bench-runs/monitor; mkdir -p "$D"
for f in $M/dpkg-baseline-*.txt; do cp "$f" "$D/"; done
cp $M/dpkg-baseline.txt "$D/dpkg-baseline-current.txt"
apt-mark showhold > "$D/apt-holds-$(date +%Y%m%d).txt"
zcat -f /var/log/apt/history.log* | python3 -c '
import re, sys
blocks = sys.stdin.read().split("\n\n"); keep = ("Start-Date:", "Commandline:", "Install:", "Upgrade:", "Remove:", "Purge:", "Downgrade:", "End-Date:")
out = []
for b in blocks:
    m = re.search(r"Start-Date: (\d{4}-\d{2}-\d{2})", b)
    if m and m.group(1) >= "2026-10-04":
        out.append((m.group(0), "\n".join(l for l in b.splitlines() if l.startswith(keep))))
print("\n\n".join(b for _, b in sorted(out)))' > "$D/apt-history.txt"
( cd "$D" && for f in $(ls | grep -v '^manifest.txt$'); do printf '%s lines=%s sha256=%s\n' "$f" "$(wc -l < "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"; done ) > "$D/manifest.txt"
echo "published to $D"
