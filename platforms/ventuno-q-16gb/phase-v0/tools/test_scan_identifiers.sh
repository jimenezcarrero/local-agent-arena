#!/bin/bash
# test_scan_identifiers.sh (D182) — scan_identifiers.py and publish_monitor.py's MAC redaction on fixtures; no real
# identifiers are read (SCAN_* values are fixed fakes).
cd "$(dirname "$0")"; T=$(mktemp -d); trap 'rm -rf $T' EXIT; fail=0; n=0
export SCAN_MACHINE_ID=0123456789abcdef0123456789abcdef SCAN_SERIAL=987654321 SCAN_HOSTNAME=fakehost SCAN_BOOT_ID=11111111-2222-3333-4444-555555555555
chk(){ n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=$((fail+1)); fi; }
scan(){ python3 -I scan_identifiers.py "$@" > $T/out 2>&1; echo $?; }
mkdir -p $T/c && printf 'START 07:47:00-08:44:00 boot=%s on fakehost\nwlp3s0: associate with <mac>\nSerialNumber: <usb-serial> SerialNumber=3\n' $SCAN_BOOT_ID > $T/c/a.txt
chk "clean plain file" "$(scan $T/c)" 0
chk "clean summary" "$(tail -1 $T/out)" "RESULT scan: CLEAN (1 files)"
chk "boot id and hostname found when asked" "$(scan --hostname --boot-id $T/c; grep -c ': \(hostname\|boot-id\) 1' $T/out)" "1
2"
mkdir -p $T/m && echo '{"MESSAGE": "wlp3s0: authenticate with 0a:1b:2c:3d:4e:5f (local address=AA-BB-CC-DD-EE-01)"}' > $T/m/k.jsonl
chk "MACs found, colon and dash" "$(scan $T/m; grep -c ': mac 2$' $T/out)" "1
1"
chk "no value printed" "$(grep -ciE '0a:1b|AA-BB' $T/out)" 0
mkdir -p $T/g && printf 'x %s y\n' $SCAN_MACHINE_ID | gzip > $T/g/log.gz
chk "machine-id inside .gz" "$(scan $T/g; grep -c 'machine-id 1' $T/out)" "1
1"
mkdir -p $T/tz/src && echo "SerialNumber: ABC123 and $SCAN_SERIAL" > $T/tz/src/j.txt && echo "fine" | gzip > $T/tz/src/inner.txt.gz && echo 'mac 01:02:03:04:05:06' | gzip >> $T/tz/src/inner.txt.gz && tar -czf $T/tz/e.tar.gz -C $T/tz src && rm -r $T/tz/src
chk "tar.gz members, nested .gz" "$(scan $T/tz; grep -cE 'j.txt: (usb-serial|soc-serial) 1|inner.txt.gz: mac 1' $T/out)" "1
3"
chk "unknown option refused" "$(scan --all $T/c)" 1
# publish_monitor.py: MACs redacted in the kernel export, time ranges and other fields kept
mkdir -p $T/mon $T/pub && echo '{"MESSAGE": "wlp3s0: authenticate with 0a:1b:2c:3d:4e:5f (local address=aa:bb:cc:dd:ee:01) at 07:47:00-08:44:00", "_BOOT_ID": "b", "_HOSTNAME": "h"}' > $T/mon/kernel-20261022.jsonl
MONITOR_DIR=$T/mon python3 -I publish_monitor.py $T/pub > /dev/null 2>&1
chk "publisher redacts MACs" "$(grep -o '<mac>' $T/pub/monitor/kernel-20261022.jsonl | wc -l)" 2
chk "publisher keeps time range and boot id, drops hostname" "$(grep -c '07:47:00-08:44:00.*"_BOOT_ID": "b"' $T/pub/monitor/kernel-20261022.jsonl; grep -c _HOSTNAME $T/pub/monitor/kernel-20261022.jsonl)" "1
0"
chk "published export scans clean" "$(scan $T/pub/monitor)" 0
echo "failures: $fail"; echo $n; [ $fail = 0 ]
