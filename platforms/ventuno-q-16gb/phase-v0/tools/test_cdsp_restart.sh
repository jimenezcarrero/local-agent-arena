#!/bin/bash
# Offline tests for cdsp_restart.sh (D92, Codex review of #45 2026-10-07 21:06Z). Never touches real sysfs, /proc,
# devices or root: a copy under a temp dir gets only its constants block rewritten (fake sysfs, fake /proc, temp
# log/lock, the current uid, 3 s step deadline). A background simulator plays the remoteproc driver
# (stop -> offline, start -> running) unless a case disables it.
SRC=${SRC:-$(dirname "$(readlink -f "$0")")/cdsp_restart.sh}; fails=0
setup() { T=$(mktemp -d); mkdir -p $T/sys/remoteproc0 $T/sys/remoteproc1 $T/proc/1/fd $T/run
  echo 3000000.remoteproc > $T/sys/remoteproc0/name; echo running > $T/sys/remoteproc0/state
  echo 26300000.remoteproc > $T/sys/remoteproc1/name; echo running > $T/sys/remoteproc1/state
  echo init > $T/proc/1/comm; ln -s /dev/null $T/proc/1/fd/0
  # D102: a fake cdsprpcd (pid 1700, exe /usr/sbin/cdsprpcd, owned by the current user standing in for fastrpc) holding
  # the device, a fake systemctl that reads $T/unit/{ActiveState,MainPID}, device nodes under $T/dev
  mkdir -p $T/proc/1700/fd $T/unit $T/dev; echo cdsprpcd > $T/proc/1700/comm; ln -s /usr/sbin/cdsprpcd $T/proc/1700/exe
  ln -s /dev/fastrpc-cdsp $T/proc/1700/fd/3; echo active > $T/unit/ActiveState; echo 1700 > $T/unit/MainPID
  touch $T/dev/fastrpc-cdsp $T/dev/fastrpc-cdsp-secure
  printf '#!/bin/bash\n[ "$1 $2 $4 $5" = "show -p --value cdsprpcd.service" ] || exit 9\n[ -e %s/unit/slow ] && sleep "$(cat %s/unit/slow)"\n[ -e %s/unit/block ] && exec sleep 1000\ncat %s/unit/$3\n' $T $T $T $T > $T/systemctl; chmod +x $T/systemctl
  sed -e "s#^EXPIRES=0\$#EXPIRES=$(( $(date +%s) + 3600 ))#" -e "s#^SYS=.*#SYS=$T/sys#" -e "s#^PROC=.*#PROC=$T/proc#" \
      -e "s#^LOG=.*#LOG=$T/log.txt#" -e "s#^LOCK=.*#LOCK=$T/run/lock#" -e "s#^NEED_UID=.*#NEED_UID=$(id -u)#" \
      -e "s#^STEP_S=.*#STEP_S=3#" -e "s#^SYSTEMCTL=.*#SYSTEMCTL=$T/systemctl#" -e "s#^DEVROOT=.*#DEVROOT=$T#" \
      -e "s#^DAEMON_USER=.*#DAEMON_USER=$(id -un)#" -e "s#^Q_S=.*#Q_S=1#" "$SRC" > $T/helper
  SIM=""; }
sim() { ( f=$T/sys/remoteproc1/state; while :; do case "$(cat $f 2>/dev/null)" in stop) echo offline > $f;; start) echo running > $f;; esac; sleep 0.2; done ) & SIM=$!; }
chk() { local name=$1 want=$2 pat=$3; shift 3; local out rc
  out=$(timeout 30 bash $T/helper "$@" 2>&1); rc=$?
  [ -n "$SIM" ] && kill $SIM 2>/dev/null; wait $SIM 2>/dev/null
  if [ $rc = $want ] && grep -qE "$pat" <<< "$out$(cat $T/log.txt 2>/dev/null)"; then echo "ok   $name (rc $rc)"
  else echo "FAIL $name (rc $rc want $want; want /$pat/)"; sed 's/^/     /' <<< "$out"; fails=$((fails+1)); fi; }
end() { rm -rf $T; }
setup; sim; chk ok 0 "OK .*running -> offline -> running"
  grep -q "BEGIN .*state running" $T/log.txt && [ $(grep -c . $T/log.txt) = 2 ] && echo "ok   ok: BEGIN then OK logged" || { echo "FAIL ok log"; fails=$((fails+1)); }
  [ "$(cat $T/sys/remoteproc1/state)" = running ] && [ "$(cat $T/sys/remoteproc0/state)" = running ] && echo "ok   only the cDSP was touched" || { echo "FAIL other remoteproc touched"; fails=$((fails+1)); }; end
setup; chk args 2 "takes no arguments" --force; end
setup; sed -i "s#^NEED_UID=.*#NEED_UID=99999#" $T/helper; chk not-root 2 "must run as root"; end
setup; sed -i "s#^EXPIRES=.*#EXPIRES=0#" $T/helper; chk unconfigured 2 "not configured"; end
setup; sed -i "s#^EXPIRES=.*#EXPIRES=$(( $(date +%s) - 60 ))#" $T/helper; chk expired 3 "REFUSED expired"; end
setup; ( flock 9; sleep 5 ) 9> $T/run/lock & sleep 0.5; chk concurrent 4 "REFUSED another restart"; wait; end
setup; mkdir -p $T/proc/4242/fd; echo genie-t2t-run > $T/proc/4242/comm; ln -s /dev/fastrpc-cdsp $T/proc/4242/fd/7
  chk other-client 4 "REFUSED cDSP clients open: 4242\(genie-t2t-run\)"; [ "$(cat $T/sys/remoteproc1/state)" = running ] || fails=$((fails+1)); end
setup; mkdir -p $T/proc/4243/fd; echo x > $T/proc/4243/comm; ln -s /dev/fastrpc-cdsp-secure $T/proc/4243/fd/3; chk secure-client 4 "REFUSED cDSP clients open"; end
setup; mkdir -p $T/proc/4244/fd; chmod 000 $T/proc/4244/fd; chk proc-unreadable 4 "quiescence not established"; chmod 755 $T/proc/4244/fd; end
setup; echo 26300000.other > $T/sys/remoteproc1/name; chk no-remoteproc 3 "FAIL no remoteproc named"; end
setup; echo offline > $T/sys/remoteproc1/state; chk bad-start-state 4 "REFUSED unexpected starting state 'offline'"; end
setup; sed -i "s#^LOG=.*#LOG=$T/no/such/dir/log.txt#" $T/helper; chk log-unwritable 3 "cannot write"
  [ "$(cat $T/sys/remoteproc1/state)" = running ] && echo "ok   log-unwritable changed nothing" || { echo "FAIL state changed"; fails=$((fails+1)); }; end
setup; chk driver-stuck 6 "FAIL state 'stop' after 'stop' \(expected offline\)"; grep -q BEGIN $T/log.txt && grep -q "FAIL state" $T/log.txt || { echo "FAIL driver-stuck log"; fails=$((fails+1)); }; end
setup; chmod 444 $T/sys/remoteproc1/state; chk write-error 5 "FAIL write 'stop' returned an error"; end
setup; rm $T/sys/remoteproc1/state; mkfifo $T/sys/remoteproc1/state; ( echo running > $T/sys/remoteproc1/state ) &
  chk write-blocks 7 "UNKNOWN write 'stop' still blocked"; grep -q BEGIN $T/log.txt && grep -q UNKNOWN $T/log.txt && echo "ok   write-blocks: BEGIN and UNKNOWN logged" || { echo "FAIL write-blocks log"; fails=$((fails+1)); }
  timeout 2 cat $T/sys/remoteproc1/state > /dev/null 2>&1; end
# Codex review of #47 (22:08Z): uninspectable but present fd entry; terminal log write failing after BEGIN
setup; mkdir -p $T/proc/4245/fd; echo y > $T/proc/4245/comm; ln -s /dev/null $T/proc/4245/fd/5; chmod 444 $T/proc/4245/fd
  chk fd-uninspectable 4 "REFUSED cannot inspect .*/4245/fd/5"; [ "$(cat $T/sys/remoteproc1/state)" = running ] && echo "ok   fd-uninspectable changed nothing" || { echo "FAIL fd-uninspectable state"; fails=$((fails+1)); }; chmod 755 $T/proc/4245/fd; end
setup; ( f=$T/sys/remoteproc1/state; while :; do case "$(cat $f 2>/dev/null)" in stop) chmod 444 $T/log.txt; echo offline > $f;; start) echo running > $f;; esac; sleep 0.2; done ) & SIM=$!
  chk log-fails-after-begin 8 "AUDIT FAIL: terminal record not written"; grep -q BEGIN $T/log.txt && ! grep -q " OK " $T/log.txt && echo "ok   log-fails-after-begin: BEGIN only, rc 8" || { echo "FAIL log-fails-after-begin log"; fails=$((fails+1)); }; end
# Codex review of #47 (22:16Z): readlink fails AND the re-listing fails (process still there) -> refuse, no mutation;
# readlink fails because the fd really vanished -> skip and restart. Fault injected only in the temp copy: a readlink
# shell function placed after the constants block.
inject() { sed -i "/^# --- end of constants ---\$/a readlink() { if [ \"\$1\" = \"$T/proc/4246/fd/5\" ]; then $1; return 1; fi; command readlink \"\$@\"; }" $T/helper; }
setup; mkdir -p $T/proc/4246/fd; echo z > $T/proc/4246/comm; ln -s /dev/fastrpc-cdsp $T/proc/4246/fd/5; inject "chmod 000 $T/proc/4246/fd"
  chk relist-fails 4 "REFUSED cannot re-list .*/4246/fd"; [ "$(cat $T/sys/remoteproc1/state)" = running ] && ! grep -q BEGIN $T/log.txt 2>/dev/null && echo "ok   relist-fails changed nothing" || { echo "FAIL relist-fails mutated"; fails=$((fails+1)); }; chmod 755 $T/proc/4246/fd; end
setup; mkdir -p $T/proc/4246/fd; echo z > $T/proc/4246/comm; ln -s /dev/null $T/proc/4246/fd/5; inject "rm -f $T/proc/4246/fd/5"; sim
  chk fd-vanished 0 "OK .*running -> offline -> running"; end
# D102 (owner choice (a) of D98): exactly the cdsprpcd daemon is exempt; it must be identified before and back after
setup; sim; chk daemon-exempt-ok 0 "OK .*running -> offline -> running; cdsprpcd.service pid 1700 -> 1700"
  grep -q "BEGIN .*cdsprpcd.service pid 1700" $T/log.txt && echo "ok   daemon-exempt-ok: BEGIN names the daemon" || { echo "FAIL BEGIN daemon"; fails=$((fails+1)); }; end
setup; rm $T/proc/1700/exe; ln -s /usr/bin/python3 $T/proc/1700/exe; chk daemon-wrong-exe 4 "REFUSED cdsprpcd.service daemon not identified"; end
setup; sed -i "s#^DAEMON_USER=.*#DAEMON_USER=root#" $T/helper; [ "$(id -u)" = 0 ] && sed -i "s#^DAEMON_USER=.*#DAEMON_USER=nobody#" $T/helper
  chk daemon-wrong-user 4 "REFUSED cdsprpcd.service daemon not identified"; end
setup; echo inactive > $T/unit/ActiveState; chk unit-inactive 4 "REFUSED cdsprpcd.service daemon not identified"
  [ "$(cat $T/sys/remoteproc1/state)" = running ] || { echo "FAIL unit-inactive state"; fails=$((fails+1)); }; end
setup; echo 0 > $T/unit/MainPID; chk unit-no-pid 4 "REFUSED cdsprpcd.service daemon not identified"; end
setup; sed -i "s#^SYSTEMCTL=.*#SYSTEMCTL=/bin/false#" $T/helper; chk unit-query-fails 4 "REFUSED cdsprpcd.service daemon not identified"; end
# a process that looks like the daemon but is not the unit's MainPID is an ordinary client
setup; mkdir -p $T/proc/4250/fd; echo cdsprpcd > $T/proc/4250/comm; ln -s /usr/sbin/cdsprpcd $T/proc/4250/exe; ln -s /dev/fastrpc-cdsp $T/proc/4250/fd/4
  chk daemon-impostor 4 "REFUSED cDSP clients open: 4250\(cdsprpcd\) \([0-9]+ s\)"; end
setup; mkdir -p $T/proc/4251/fd; echo llama-server > $T/proc/4251/comm; ln -s /dev/fastrpc-cdsp $T/proc/4251/fd/9
  chk daemon-plus-client 4 "REFUSED cDSP clients open: 4251\(llama-server\)"; end
# after the restart: daemon restarted by systemd with a new PID -> OK; unit failed or device node missing -> FAIL 9
simd() { ( f=$T/sys/remoteproc1/state; while :; do case "$(cat $f 2>/dev/null)" in
    stop) echo offline > $f; eval "$1";; start) echo running > $f; eval "$2";; esac; sleep 0.2; done ) & SIM=$!; }
setup; mkdir -p $T/proc/1800/fd; ln -s /usr/sbin/cdsprpcd $T/proc/1800/exe
  simd "rm -f $T/dev/fastrpc-cdsp*; echo activating > $T/unit/ActiveState" "touch $T/dev/fastrpc-cdsp $T/dev/fastrpc-cdsp-secure; echo 1800 > $T/unit/MainPID; echo active > $T/unit/ActiveState"
  chk daemon-new-pid 0 "OK .*cdsprpcd.service pid 1700 -> 1800"; end
setup; simd "echo failed > $T/unit/ActiveState" ":"; chk daemon-not-back 9 "FAIL cdsprpcd.service not active"
  grep -q BEGIN $T/log.txt && grep -q "FAIL cdsprpcd" $T/log.txt && echo "ok   daemon-not-back: BEGIN and FAIL logged" || { echo "FAIL daemon-not-back log"; fails=$((fails+1)); }; end
setup; simd "rm -f $T/dev/fastrpc-cdsp-secure" ":"; chk device-not-back 9 "FAIL cdsprpcd.service not active with a verified daemon and device nodes"; end
# Codex review of #47 (12:15Z): stuck or slow systemctl queries must end in an audited outcome within the deadline
# (STEP_S=3, Q_S=1 here: the post-check must end within STEP_S + 10 s, the whole call well under the 30 s chk limit)
elapsed() { local a=$(date +%s); chk "$@"; local e=$(( $(date +%s) - a )); [ $e -le $LIM ] && echo "ok   ${1}: ${e} s <= ${LIM} s" || { echo "FAIL ${1}: ${e} s > ${LIM} s"; fails=$((fails+1)); }; }
setup; touch $T/unit/block; LIM=5 elapsed query-blocks-before 4 "REFUSED cdsprpcd.service daemon not identified"
  [ "$(cat $T/sys/remoteproc1/state)" = running ] && ! grep -q BEGIN $T/log.txt && echo "ok   query-blocks-before changed nothing" || { echo "FAIL query-blocks-before mutated"; fails=$((fails+1)); }; end
setup; simd ":" "touch $T/unit/block"; LIM=16 elapsed query-blocks-after 9 "FAIL cdsprpcd.service not active"
  grep -q BEGIN $T/log.txt && grep -q "FAIL cdsprpcd" $T/log.txt && echo "ok   query-blocks-after: BEGIN and FAIL logged" || { echo "FAIL query-blocks-after log"; fails=$((fails+1)); }; end
setup; simd ":" "echo 0.9 > $T/unit/slow; echo failed > $T/unit/ActiveState"; LIM=16 elapsed query-slow-after 9 "FAIL cdsprpcd.service not active"; end
echo "failures: $fails"; exit $fails
