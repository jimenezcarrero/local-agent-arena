#!/bin/bash
# offline tests for r2_mapped_peak.py on synthetic logs in the af0579c78 verbose format (no NPU)
D=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT; fails=0; n=0
M=$((1024 * 1024))
mp() { echo "0.01.000 D ggml-hex: $1 mapped buffer: base 0x7f00 size $2 fd $3 pinned $4 extended 0"; }
um() { echo "0.02.000 D ggml-hex: $1 unmapped buffer: base 0x7f00 size $2 fd $3"; }
expect() { local name=$1 want=$2; shift 2; n=$((n + 1)); out=$(python3 -I "$D/r2_mapped_peak.py" "$@" 2>&1); rc=$?
  [ "$rc" = "$want" ] && echo "ok   $name (rc $rc: $(echo "$out" | tail -1))" || { echo "FAIL $name (rc $rc, wanted $want): $(echo "$out" | tail -2 | tr '\n' ' ')"; fails=$((fails + 1)); }; }
{ for s in 0 1; do mp HTP0:$s $((10 * M)) 1$s 1; mp HTP0:$s $((1000 * M)) 2$s 0; mp HTP0:$s $((500 * M)) 3$s 0; done
  mp HTP0:1 $((200 * M)) 30 0          # a clone of session 0's compute buffer (fd 30) mapped by session 1
  um HTP0:1 $((200 * M)) 30; mp HTP0:1 $((100 * M)) 40 0; } > "$W/a.log"
expect "within: peaks 1500 / 1700 MiB against 1600 / 1800" 0 "$W/a.log" 1600,1800 --sessions HTP0:0,HTP0:1
n=$((n + 1)); python3 -I "$D/r2_mapped_peak.py" "$W/a.log" 1600,1800 --sessions HTP0:0,HTP0:1 | grep -q '^HTP0:1: peak 1700.0 MiB own+clones (limit 1800.0), pinned 10.0' \
  && echo "ok   the clone counts in the receiving session; the pinned buffer is reported apart" || { echo "FAIL peak arithmetic"; fails=$((fails + 1)); }
expect "over: session 1's 1700 MiB against 1650" 1 "$W/a.log" 1600,1650 --sessions HTP0:0,HTP0:1
expect "a listed session without mapping lines: invalid" 3 "$W/a.log" 1600,1800,1800 --sessions HTP0:0,HTP0:1,HTP0:2
expect "a session in the log that is not listed: invalid" 3 "$W/a.log" 1600 --sessions HTP0:0
{ mp HTP0:0 100 5 0; mp HTP0:0 100 5 0; } > "$W/b.log"; expect "the same fd mapped twice: invalid" 3 "$W/b.log" 1600 --sessions HTP0:0
{ mp HTP0:0 100 5 0; um HTP0:0 100 6; } > "$W/c.log"; expect "an unmap of an unmapped fd: invalid" 3 "$W/c.log" 1600 --sessions HTP0:0
{ mp HTP0:0 100 5 0; echo "ggml-hex: HTP0:0 mapped buffer: size ?"; } > "$W/d.log"; expect "a malformed mapping line: invalid" 3 "$W/d.log" 1600 --sessions HTP0:0
expect "no log: invalid" 3 "$W/none.log" 1600 --sessions HTP0:0
mp HTP0:0 $((3300 * M)) 7 0 > "$W/e.log"; mp HTP0:0 $((10 * M)) 8 1 >> "$W/e.log"
expect "total over 3,200 MiB even within the own limit: over" 1 "$W/e.log" 4000 --sessions HTP0:0
echo "failures: $fails of $n"; exit $fails
