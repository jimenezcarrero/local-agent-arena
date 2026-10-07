#!/bin/bash
# install_cdsp_restart.sh --expires YYYY-MM-DDTHH:MM | --uninstall — run by the owner with sudo (D91, D92):
#   sudo bash platforms/ventuno-q-16gb/phase-v0/tools/install_cdsp_restart.sh --expires 2026-10-08T09:00
#   sudo bash platforms/ventuno-q-16gb/phase-v0/tools/install_cdsp_restart.sh --uninstall
# Installs tools/cdsp_restart.sh as /usr/local/sbin/v0-cdsp-restart (root:root 0755) with the expiry written into it
# (the helper refuses after that time; at most 24 h ahead), and /etc/sudoers.d/v0-cdsp-restart (root:root 0440), which
# lets the arduino user run exactly that file, with no arguments, without a password. Nothing else gains root.
# Order: everything is staged and checked (expiry, helper syntax, visudo on the rule) before anything is installed.
# --uninstall removes the rule first, then the helper; the log /var/log/v0-cdsp-restart.log is kept as evidence.
set -euo pipefail
BIN=/usr/local/sbin/v0-cdsp-restart; RULE=/etc/sudoers.d/v0-cdsp-restart
usage() { echo "usage: sudo bash $0 --expires YYYY-MM-DDTHH:MM | --uninstall" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
if [ $# = 1 ] && [ "$1" = --uninstall ]; then rm -f "$RULE" "$BIN"; echo "removed $RULE and $BIN"; exit 0; fi
[ $# = 2 ] && [ "$1" = --expires ] || usage
[[ "$2" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]$ ]] || usage
exp=$(date -d "$2" +%s) || usage
now=$(date +%s)
[ "$exp" -gt "$now" ] && [ "$exp" -le $((now + 86400)) ] || { echo "expiry must be in the next 24 h" >&2; exit 2; }
SRC=$(dirname "$(readlink -f "$0")")/cdsp_restart.sh
tmpd=$(mktemp -d); trap 'rm -rf "$tmpd"' EXIT
grep -qx 'EXPIRES=0' "$SRC" || { echo "helper source has no EXPIRES=0 line" >&2; exit 3; }
sed "s/^EXPIRES=0\$/EXPIRES=$exp/" "$SRC" > "$tmpd/helper"
grep -qx "EXPIRES=$exp" "$tmpd/helper" && bash -n "$tmpd/helper"
# "" after the command = no arguments allowed
echo "arduino ALL=(root) NOPASSWD: $BIN \"\"" > "$tmpd/rule"
visudo -cf "$tmpd/rule" > /dev/null
install -o root -g root -m 0755 "$tmpd/helper" "$BIN"
install -o root -g root -m 0440 "$tmpd/rule" "$RULE"
visudo -c > /dev/null || { rm -f "$RULE"; echo "sudoers check failed; rule removed" >&2; exit 3; }
echo "installed $BIN (sha256 $(sha256sum "$BIN" | cut -c1-64), expires $(date -d @"$exp" -Is)) and $RULE:"; cat "$RULE"
