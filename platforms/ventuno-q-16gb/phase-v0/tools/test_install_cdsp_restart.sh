#!/bin/bash
# Offline tests for install_cdsp_restart.sh (D103, Codex review of #47 2026-10-08 12:15Z). Never runs as root and never
# touches /usr/local/sbin, /etc/sudoers.d or /run: a copy under a temp dir gets only its constants block rewritten
# (temp paths, the current uid, no chown, fake visudo and sudo). Failures are injected by a shell function placed
# after the constants block of the copy. Central property: after a failed (re)installation no rule exists.
SRC=${SRC:-$(dirname "$(readlink -f "$0")")/install_cdsp_restart.sh}; fails=0
EXP=$(date -d '+2 hours' +%Y-%m-%dT%H:%M)
setup() { T=$(mktemp -d); mkdir -p $T/tools $T/sbin $T/sudoers.d $T/run
  cp "$(dirname "$SRC")/cdsp_restart.sh" $T/tools/cdsp_restart.sh
  printf '#!/bin/bash\nexit 0\n' > $T/visudo
  # fake sudo -l: lists the rule's command if the rule file exists (as sudo would after loading it)
  printf '#!/bin/bash\n[ -e %s ] && echo "    (root) NOPASSWD: $(sed -n "s/.*NOPASSWD: //p" %s)"\nexit 0\n' $T/sudoers.d/v0-cdsp-restart $T/sudoers.d/v0-cdsp-restart > $T/sudo
  chmod +x $T/visudo $T/sudo
  sed -e "s#^BIN=.*#BIN=$T/sbin/v0-cdsp-restart#" -e "s#^RULE=.*#RULE=$T/sudoers.d/v0-cdsp-restart#" \
      -e "s#^LOCK=.*#LOCK=$T/run/lock#" -e "s#^LOCK_WAIT=.*#LOCK_WAIT=2#" -e "s#^NEED_UID=.*#NEED_UID=$(id -u)#" \
      -e 's#^OWN=.*#OWN=""#' -e "s#^VISUDO=.*#VISUDO=$T/visudo#" -e "s#^SUDO=.*#SUDO=$T/sudo#" "$SRC" > $T/tools/install.sh; }
old() { echo "old helper" > $T/sbin/v0-cdsp-restart; echo "arduino ALL=(root) NOPASSWD: $T/sbin/v0-cdsp-restart \"\"" > $T/sudoers.d/v0-cdsp-restart; }
inject() { sed -i "/^# --- end of constants ---\$/a $1" $T/tools/install.sh; }
res() { local name=$1 want=$2 cond=$3; shift 3; local rc
  out=$(timeout 30 bash $T/tools/install.sh "$@" 2>&1); rc=$?
  if [ $rc = $want ] && eval "$cond"; then echo "ok   $name (rc $rc)"
  else echo "FAIL $name (rc $rc want $want; cond: $cond)"; sed 's/^/     /' <<< "$out"; ls -la $T/sbin $T/sudoers.d | sed 's/^/     /'; fails=$((fails+1)); fi; }
end() { rm -rf $T; }
NOGRANT='[ ! -e $T/sudoers.d/v0-cdsp-restart ] && [ ! -e $T/sudoers.d/.v0-cdsp-restart.new ] && [ ! -e $T/sbin/v0-cdsp-restart ] && [ ! -e $T/sbin/v0-cdsp-restart.new ]'
NEWPAIR='grep -q "^EXPIRES=[1-9]" $T/sbin/v0-cdsp-restart && grep -qF "NOPASSWD: $T/sbin/v0-cdsp-restart \"\"" $T/sudoers.d/v0-cdsp-restart && [ ! -e $T/sudoers.d/.v0-cdsp-restart.new ]'
setup; res fresh-install 0 "$NEWPAIR" --expires $EXP; end
setup; old; res reinstall 0 "$NEWPAIR" --expires $EXP; end
# each publication stage fails in turn, over an existing installation: the grant must end absent
setup; old; inject 'mv() { [ "${@: -1}" = "$BIN" ] \&\& return 1; command mv "$@"; }'; res fail-publish-helper 3 "$NOGRANT" --expires $EXP; end
setup; old; inject 'install() { [ "${@: -1}" = "$BIN.new" ] \&\& return 1; command install "$@"; }'; res fail-stage-helper 3 "$NOGRANT" --expires $EXP; end
setup; old; inject 'install() { case "${@: -1}" in *.v0-cdsp-restart.new) return 1;; esac; command install "$@"; }'; res fail-stage-rule 3 "$NOGRANT" --expires $EXP; end
setup; old; inject 'mv() { [ "${@: -1}" = "$RULE" ] \&\& return 1; command mv "$@"; }'; res fail-publish-rule 3 "$NOGRANT" --expires $EXP; end
setup; old; printf '#!/bin/bash\nexit 0\n' > $T/sudo; res fail-postcheck-sudo 3 "$NOGRANT" --expires $EXP; end
setup; old; printf '#!/bin/bash\n[ "$2" = %s ] && exit 1; exit 0\n' $T/sudoers.d/v0-cdsp-restart > $T/visudo; res fail-postcheck-visudo 3 "$NOGRANT" --expires $EXP; end
# the old rule is removed before the new helper is published (no moment where the old grant covers the new helper)
setup; old; inject 'mv() { [ "${@: -1}" = "$BIN" ] \&\& [ -e "$RULE" ] \&\& echo RULE_PRESENT >> '$T'/order; command mv "$@"; }'
  res rule-removed-first 0 "[ ! -e $T/order ] && $NEWPAIR" --expires $EXP; end
# a restart in progress holds the lock: the installer waits, then gives up without changing anything
setup; old; ( flock 9; sleep 6 ) 9> $T/run/lock & sleep 0.5
  res lock-held 3 'grep -qx "old helper" $T/sbin/v0-cdsp-restart && grep -q "lock\|still running" <<< "$out"' --expires $EXP; wait; end
# checks that stop before publication leave an existing installation untouched
setup; old; res bad-expiry 2 'grep -qx "old helper" $T/sbin/v0-cdsp-restart' --expires 2099-01-01T00:00; end
setup; old; printf '#!/bin/bash\nexit 1\n' > $T/visudo; res staged-rule-rejected 3 'grep -qx "old helper" $T/sbin/v0-cdsp-restart' --expires $EXP; end
setup; old; res uninstall 0 "$NOGRANT" --uninstall; end
echo "failures: $fails"; exit $fails
