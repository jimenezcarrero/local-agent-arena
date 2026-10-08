#!/bin/bash
# install_cdsp_restart.sh --expires YYYY-MM-DDTHH:MM | --uninstall — run by the owner with sudo (D91, D92, D102):
#   sudo bash platforms/ventuno-q-16gb/phase-v0/tools/install_cdsp_restart.sh --expires 2026-10-09T09:00
#   sudo bash platforms/ventuno-q-16gb/phase-v0/tools/install_cdsp_restart.sh --uninstall
# Installs tools/cdsp_restart.sh as /usr/local/sbin/v0-cdsp-restart (root:root 0755) with the expiry written into it
# (the helper refuses after that time; at most 24 h ahead), and /etc/sudoers.d/v0-cdsp-restart (root:root 0440), which
# lets the arduino user run exactly that file, with no arguments, without a password. Nothing else gains root.
# Order: everything is staged and checked (expiry, helper syntax, visudo on the rule) before anything is installed.
# Publication (Codex review of #47, 12:15Z: a failed reinstallation must not leave a new helper under an old grant):
#   1. take the helper's own lock (a restart in progress finishes first; new calls refuse while it is held)
#   2. remove any existing rule: from here on, no grant exists until step 4 succeeds
#   3. publish the helper: staged copy next to it, then an atomic rename
#   4. publish the rule: staged as /etc/sudoers.d/.v0-cdsp-restart.new (sudo ignores names containing "."), then an
#      atomic rename
#   5. post-check (D95): visudo -cf on the installed rule, and sudo lists the helper as NOPASSWD
#   Any failure in 2-5 removes the rule, the helper and the staged copies, and exits 3: the grant is left absent.
# --uninstall removes the rule first, then the helper; the log /var/log/v0-cdsp-restart.log is kept as evidence.
# Overridable for tests (tools/test_install_cdsp_restart.sh): only the constants block, in a temp copy.
set -uo pipefail
# --- constants ---
BIN=/usr/local/sbin/v0-cdsp-restart
RULE=/etc/sudoers.d/v0-cdsp-restart
LOCK=/run/v0-cdsp-restart.lock
LOCK_WAIT=150
NEED_UID=0
OWN="-o root -g root"
VISUDO=visudo
SUDO=sudo
# --- end of constants ---
RULE_NEW=$(dirname "$RULE")/.v0-cdsp-restart.new; BIN_NEW=$BIN.new
usage() { echo "usage: sudo bash $0 --expires YYYY-MM-DDTHH:MM | --uninstall" >&2; exit 2; }
[ "$(id -u)" = "$NEED_UID" ] || { echo "run with sudo" >&2; exit 2; }
if [ $# = 1 ] && [ "$1" = --uninstall ]; then rm -f "$RULE" "$RULE_NEW" && rm -f "$BIN" "$BIN_NEW" && echo "removed $RULE and $BIN" && exit 0
  echo "uninstall failed; check $RULE and $BIN" >&2; exit 3; fi
[ $# = 2 ] && [ "$1" = --expires ] || usage
[[ "$2" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]$ ]] || usage
exp=$(date -d "$2" +%s) || usage
now=$(date +%s)
[ "$exp" -gt "$now" ] && [ "$exp" -le $((now + 86400)) ] || { echo "expiry must be in the next 24 h" >&2; exit 2; }
SRC=$(dirname "$(readlink -f "$0")")/cdsp_restart.sh
tmpd=$(mktemp -d) || exit 3; trap 'rm -rf "$tmpd"' EXIT
grep -qx 'EXPIRES=0' "$SRC" || { echo "helper source has no EXPIRES=0 line" >&2; exit 3; }
sed "s/^EXPIRES=0\$/EXPIRES=$exp/" "$SRC" > "$tmpd/helper" || exit 3
grep -qx "EXPIRES=$exp" "$tmpd/helper" && bash -n "$tmpd/helper" || { echo "staged helper invalid" >&2; exit 3; }
# "" after the command = no arguments allowed
echo "arduino ALL=(root) NOPASSWD: $BIN \"\"" > "$tmpd/rule" || exit 3
"$VISUDO" -cf "$tmpd/rule" > /dev/null || { echo "staged rule rejected by visudo" >&2; exit 3; }
# --- publication: from step 2 on, any failure leaves no grant ---
abort() { rm -f "$RULE" "$RULE_NEW"; rm -f "$BIN" "$BIN_NEW"
  if [ -e "$RULE" ] || [ -e "$RULE_NEW" ]; then echo "FAILED at: $1; COULD NOT REMOVE THE RULE, remove $RULE by hand" >&2
  else echo "FAILED at: $1; no rule installed (grant absent), helper removed" >&2; fi; exit 3; }
exec 9> "$LOCK" || { echo "cannot open $LOCK; nothing changed" >&2; exit 3; }
flock -w "$LOCK_WAIT" 9 || { echo "a restart is still running after ${LOCK_WAIT}s; nothing changed" >&2; exit 3; }
rm -f "$RULE" "$RULE_NEW" && [ ! -e "$RULE" ] || abort "removing the existing rule"
install $OWN -m 0755 "$tmpd/helper" "$BIN_NEW" || abort "staging the helper"
mv -f "$BIN_NEW" "$BIN" || abort "publishing the helper"
install $OWN -m 0440 "$tmpd/rule" "$RULE_NEW" || abort "staging the rule"
mv -f "$RULE_NEW" "$RULE" || abort "publishing the rule"
# Post-install check of what this installer owns (D95): the board image ships vendor sudoers.d files with modes other
# than 0440, so a whole-configuration "visudo -c" fails regardless of this rule. Check the installed rule itself, and
# that sudo lists this command as NOPASSWD (a listing, not an execution test).
"$VISUDO" -cf "$RULE" > /dev/null || abort "post-check: visudo -cf on the installed rule"
"$SUDO" -l -U arduino 2>/dev/null | grep -qE "NOPASSWD: $BIN( |\$)" || abort "post-check: sudo -l -U arduino does not list the helper"
echo "installed $BIN (sha256 $(sha256sum "$BIN" | cut -c1-64), expires $(date -d @"$exp" -Is)) and $RULE:"; cat "$RULE"
