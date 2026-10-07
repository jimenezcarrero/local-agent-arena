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
  sed -e "s#^EXPIRES=0\$#EXPIRES=$(( $(date +%s) + 3600 ))#" -e "s#^SYS=.*#SYS=$T/sys#" -e "s#^PROC=.*#PROC=$T/proc#" \
      -e "s#^LOG=.*#LOG=$T/log.txt#" -e "s#^LOCK=.*#LOCK=$T/run/lock#" -e "s#^NEED_UID=.*#NEED_UID=$(id -u)#" \
      -e "s#^STEP_S=.*#STEP_S=3#" "$SRC" > $T/helper
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
echo "failures: $fails"; exit $fails
