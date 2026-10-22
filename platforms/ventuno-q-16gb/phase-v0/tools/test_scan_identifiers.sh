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
# Codex review of 5d766a4: punctuation beside an address, nested containers, missing paths
mkdir -p $T/p && printf 'peer:0a:1b:2c:3d:4e:5f\n0a-1b-2c-3d-4e-60: connected\nx=(0A:1B:2C:3D:4E:61), [0a-1b-2c-3d-4e-62]-up\n' > $T/p/k.txt
chk "MACs beside punctuation, both separators" "$(scan $T/p; grep -c ': mac 4$' $T/out)" "1
1"
mkdir -p $T/keep && printf 'at 07:47:00-08:44:00 boot=%s sha256 9febe63d5a379f8568bae7116a5b2ba844a4a4a6 2026-10-22T03:54:14+02:00 g0a:1b:2c:3d:4e:5fz\n' $SCAN_BOOT_ID > $T/keep/k.txt
chk "time range, boot id, hash, timestamp, letter-bound pairs not a MAC" "$(scan $T/keep)" 0
mkdir -p $T/gg && printf 'x %s y\n' $SCAN_MACHINE_ID | gzip | gzip > $T/gg/log.gz.gz
chk "gzip of gzip" "$(scan $T/gg; grep -c 'machine-id 1' $T/out)" "1
1"
mkdir -p $T/nt/in $T/nt/out && printf 'x %s y\n' $SCAN_MACHINE_ID | gzip > $T/nt/in/evidence.txt.gz && tar -czf $T/nt/out/inner.tar.gz -C $T/nt/in evidence.txt.gz && tar -czf $T/nt/outer.tar.gz -C $T/nt/out inner.tar.gz && rm -r $T/nt/in $T/nt/out
chk "tar.gz in tar.gz with a .gz member" "$(scan $T/nt; grep -c 'inner.tar.gz:evidence.txt.gz: machine-id 1' $T/out)" "1
1"
# V7 tar (no "ustar" signature) with a gzipped member, plain and gzip-wrapped (Codex review of b064a23)
mkdir -p $T/v7 && printf 'x %s y\n' $SCAN_MACHINE_ID | gzip > $T/v7m.gz && python3 -I -c '
import sys, tarfile
src, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
    t.add(src, arcname="evidence.txt.gz")
b = bytearray(open(out, "rb").read())
b[257:265] = bytes(8); b[148:156] = b" " * 8          # V7: no magic or version; checksum over the new header
b[148:156] = b"%06o\0 " % sum(b[:512])
open(out, "wb").write(bytes(b))' $T/v7m.gz $T/v7/e.tar && rm $T/v7m.gz && gzip -c $T/v7/e.tar > $T/v7/e.tar.gz
chk "fixture is V7 (no ustar) and readable" "$(python3 -I -c "import sys,tarfile; d=open(sys.argv[1],'rb').read(); print(d[257:262]==b'ustar', tarfile.open(sys.argv[1]).getnames())" $T/v7/e.tar)" "False ['evidence.txt.gz']"
chk "V7 tar with a .gz member, plain and gzipped" "$(scan $T/v7; grep -c 'evidence.txt.gz: machine-id 1' $T/out)" "1
2"
mkdir -p $T/deep && printf 'clean\n' | gzip | gzip | gzip | gzip | gzip | gzip | gzip | gzip | gzip | gzip > $T/deep/x.gz
chk "nesting deeper than the limit is an error" "$(scan $T/deep; grep -c 'nested deeper' $T/out)" "2
1"
mkdir -p $T/z && python3 -I -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1],'w').writestr('a.txt','$SCAN_MACHINE_ID')" $T/z/e.zip
chk "zip refused, not scanned as bytes" "$(scan $T/z; grep -c 'unsupported container (zip)' $T/out)" "2
1"
chk "missing path is an error" "$(scan $T/nonexistent; tail -1 $T/out | cut -c1-19)" "2
RESULT scan: ERROR "
chk "missing path beside a clean one is an error" "$(scan $T/c $T/nonexistent)" 2
chk "error output holds no identifier" "$(scan $T/z $T/deep; grep -c $SCAN_MACHINE_ID $T/out)" "2
0"
# publish_monitor.py: MACs redacted in the kernel export, time ranges and other fields kept
mkdir -p $T/mon $T/pub && echo '{"MESSAGE": "wlp3s0: authenticate with 0a:1b:2c:3d:4e:5f (local address=aa:bb:cc:dd:ee:01) at 07:47:00-08:44:00 peer:0a-1b-2c-3d-4e-60: up", "_BOOT_ID": "b", "_HOSTNAME": "h"}' > $T/mon/kernel-20261022.jsonl
MONITOR_DIR=$T/mon python3 -I publish_monitor.py $T/pub > /dev/null 2>&1
chk "publisher redacts MACs, also beside punctuation" "$(grep -o '<mac>' $T/pub/monitor/kernel-20261022.jsonl | wc -l)" 3
chk "publisher keeps time range and boot id, drops hostname" "$(grep -c '07:47:00-08:44:00.*"_BOOT_ID": "b"' $T/pub/monitor/kernel-20261022.jsonl; grep -c _HOSTNAME $T/pub/monitor/kernel-20261022.jsonl)" "1
0"
chk "published export scans clean" "$(scan $T/pub/monitor)" 0
echo "failures: $fail"; echo $n; [ $fail = 0 ]
