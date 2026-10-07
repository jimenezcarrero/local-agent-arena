#!/bin/bash
# tests for kernel_audit.py (Codex review of #45, 2026-10-06 20:32Z, finding 1): synthetic journal lines per class, plus
# an offline regression on the published GPU-lockup journal (runs/v0d-spec4b/dl-4B-d08-n4-gpu must be a fault).
KA=${KA:-$HOME/v0/kernel_audit.py}; REPO=${REPO:-$HOME/Repositories/local-agent-arena/platforms/ventuno-q-16gb/phase-v0}
T=$(mktemp -d); fails=0; mkdir -p $T/mon $T/run
printf "2026-10-07T10:00:00+02:00 START label=x\n2026-10-07T10:05:00+02:00 END rc=0\n" > $T/run/run.txt
t0=$(date -d 2026-10-07T10:00:00+02:00 +%s)
kl() { python3 -c 'import json,sys; print(json.dumps({"__REALTIME_TIMESTAMP": str(int(sys.argv[1])*1000000), "MESSAGE": sys.argv[2]}))' "$1" "$2"; }
chk() { local name=$1 want=$2 wrc=$3; shift 3; : > $T/mon/kernel-20261007.jsonl
  for l in "$@"; do kl "${l%%|*}" "${l#*|}" >> $T/mon/kernel-20261007.jsonl; done
  local out rc; out=$(MONITOR_DIR=$T/mon python3 $KA $T/run); rc=$?; local v=${out%% *}; v=${v%%$'\n'*}
  if [ "$v" = "$want" ] && [ $rc = $wrc ]; then echo "ok   $name -> $v rc=$rc"; else echo "FAIL $name -> $v rc=$rc (want $want rc=$wrc)"; fails=$((fails+1)); fi; }
chk quiet pass 0
chk outside-window pass 0 "$((t0-60))|adreno 3d00000.gpu: [drm:a6xx_fault_detect_irq [msm]] *ERROR* gpu fault"
chk benign-noalert pass 0 "$((t0+10))|wlan0: link becomes ready"
chk gpu-fault fault 1 "$((t0+10))|adreno 3d00000.gpu: [drm:a6xx_fault_detect_irq [msm]] *ERROR* gpu fault ring 0"
chk smmu fault 1 "$((t0+10))|arm-smmu 15000000.iommu: Unhandled context fault: fsr=0x402"
chk dsp-crash fault 1 "$((t0+10))|qcom_q6v5_pas 26300000.remoteproc: fatal error received: err_qdi.c"
chk fastrpc-other fault 1 "$((t0+10))|qcom,fastrpc-cb 26300000.remoteproc:glink-edge:fastrpc:compute-cb@2: invoke timed out"
chk oom fault 1 "$((t0+10))|Out of memory: Killed process 1234 (llama-server)"
chk npu-map npu_map 0 "$((t0+10))|qcom,fastrpc-cb 26300000.remoteproc:glink-edge:fastrpc:compute-cb@2: failed to map buffer, fd = 57"
chk map-plus-fault fault 1 "$((t0+10))|qcom,fastrpc-cb x: failed to map buffer, fd = 5" "$((t0+20))|adreno 3d00000.gpu: CP | opcode error"
chk usb-allowed pass 0 "$((t0+10))|usb 4-1: USB disconnect, device number 2"
chk unknown unknown 2 "$((t0+10))|some driver: probe error -22"
chk end-plus-30 fault 1 "$((t0+320))|adreno 3d00000.gpu: hangcheck detected gpu lockup"
chk after-window pass 0 "$((t0+340))|adreno 3d00000.gpu: hangcheck detected gpu lockup"
rm $T/mon/kernel-20261007.jsonl; out=$(MONITOR_DIR=$T/mon python3 $KA $T/run); rc=$?
[ $rc = 3 ] && echo "ok   no-journal -> rc 3" || { echo "FAIL no-journal rc=$rc"; fails=$((fails+1)); }
printf "garbage\n" > $T/run/run.txt; out=$(MONITOR_DIR=$T/mon python3 $KA $T/run); rc=$?
[ $rc = 3 ] && echo "ok   no-window -> rc 3" || { echo "FAIL no-window rc=$rc"; fails=$((fails+1)); }
# offline regression: the published GPU-lockup run (D82) and a clean NPU run from the published journal
out=$(MONITOR_DIR=$REPO/monitor python3 $KA $REPO/runs/v0d-spec4b/dl-4B-d08-n4-gpu); rc=$?
[ $rc = 1 ] && [ "${out%% *}" = fault ] && echo "ok   published GPU lockup -> $(head -1 <<< "$out" | cut -d'(' -f1)" || { echo "FAIL published GPU lockup rc=$rc"; fails=$((fails+1)); }
out=$(MONITOR_DIR=$REPO/monitor python3 $KA $REPO/runs/v0d-spec3/4B-mtpbase-n1-npu); rc=$?
[ $rc = 0 ] && [ "${out%% *}" = pass ] && echo "ok   published NPU MTP run -> pass" || { echo "FAIL published NPU MTP run rc=$rc"; fails=$((fails+1)); }
rm -rf $T; echo "failures: $fails"; exit $fails
