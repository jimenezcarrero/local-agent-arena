#!/bin/bash
# install_cdsp_restart.sh [--uninstall] — run once by the owner with sudo (D91):
#   sudo bash platforms/ventuno-q-16gb/phase-v0/tools/install_cdsp_restart.sh
# Installs tools/cdsp_restart.sh as /usr/local/sbin/v0-cdsp-restart (root:root 0755) and the sudoers rule
# /etc/sudoers.d/v0-cdsp-restart (root:root 0440), which lets the arduino user run exactly that file, with no
# arguments, without a password. Nothing else gains root. The rule is syntax-checked with visudo before it is put in
# place. --uninstall removes both files (the log /var/log/v0-cdsp-restart.log is kept as evidence).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
BIN=/usr/local/sbin/v0-cdsp-restart; RULE=/etc/sudoers.d/v0-cdsp-restart
if [ "${1:-}" = --uninstall ]; then rm -f "$RULE" "$BIN"; echo "removed $RULE and $BIN"; exit 0; fi
SRC=$(dirname "$(readlink -f "$0")")/cdsp_restart.sh
install -o root -g root -m 0755 "$SRC" "$BIN"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
# "" after the command = no arguments allowed
echo "arduino ALL=(root) NOPASSWD: $BIN \"\"" > "$tmp"
visudo -cf "$tmp" > /dev/null
install -o root -g root -m 0440 "$tmp" "$RULE"
echo "installed $BIN (sha256 $(sha256sum "$BIN" | cut -c1-64)) and $RULE:"; cat "$RULE"
