#!/bin/bash
# test_mac_verify.sh — regressions for the MAC-rewrite verifier and target discovery on a fixture repo with a fake
# address (aa:bb:cc:dd:ee:01). A wrapper "git" on PATH fails the object readers in chosen ways; none may end in PASS.
S=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf $T' EXIT; fail=0; n=0
REAL=$(command -v git)
chk(){ n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=$((fail+1)); fi; }
# fixture: orig with a target in two commits, new = the filtered rewrite
G="$REAL -c user.name=t -c user.email=t@t"
$REAL init -q $T/w; cd $T/w
echo 'before' > a.txt; $G add a.txt; $G commit -qm one
printf 'wifi aa:bb:cc:dd:ee:01 up\n' > b.txt; $G add b.txt; $G commit -qm two
printf 'peer AA-BB-CC-DD-EE-01\n' >> b.txt; $G commit -qam three
$REAL clone -q --bare $T/w $T/orig.git; $REAL clone -q --bare $T/orig.git $T/new.git
echo 'aa:bb:cc:dd:ee:01' > $T/targets.txt
$REAL -C $T/new.git fast-export --all --reference-excluded-parents --export-marks=$T/old.marks \
  | TARGETS=$T/targets.txt python3 -I $S/mac_filter.py 2>/dev/null \
  | $REAL -C $T/new.git fast-import --force --quiet --export-marks=$T/new.marks
$REAL -C $T/new.git reflog expire --expire=now --all; $REAL -C $T/new.git gc -q --prune=now
mkdir $T/bin; cat > $T/bin/git <<EOF
#!/bin/bash
# fake git: FAKE=<mode> breaks one reader, everything else goes to the real git
all=0; batch=0; for a in "\$@"; do [ "\$a" = --batch-all-objects ] && all=1; [ "\$a" = --batch ] && batch=1; done
if [ "\$all" = 1 ] && [ "\$batch" = 1 ]; then
  case \${FAKE:-} in
    exit-before) exit 7;;
    exit-midway) $REAL "\$@" | head -c 400; exit 7;;
    cut-rc0) $REAL "\$@" | head -c 400; exit 0;;
    one-record-rc0) $REAL "\$@" | python3 -I -c 'import sys; i=sys.stdin.buffer; h=i.readline(); sys.stdout.buffer.write(h+i.read(int(h.split()[2])+1))'; exit 0;;
  esac
fi
if [ "\$batch" = 1 ] && [ "\$all" = 0 ] && [ "\${FAKE:-}" = cat-exit ]; then exit 7; fi
exec $REAL "\$@"
EOF
chmod +x $T/bin/git
v(){ FAKE=$1 PATH=$T/bin:$PATH python3 -I $S/mac_verify.py $T/orig.git $T/new.git $T/old.marks $T/new.marks \
       $T/targets.txt $T/map.txt > $T/out 2>&1; echo $?; }
chk "normal rewrite verifies" "$(v ''; tail -1 $T/out)" "0
VERIFY: PASS"
chk "residual reader exits before listing" "$(v exit-before; grep -c 'exited 7' $T/out; tail -1 $T/out | cut -c1-14)" "1
1
VERIFY: FAIL ("
chk "residual reader exits midway" "$(v exit-midway; grep -cE 'truncated|exited 7' $T/out; grep -c '^VERIFY: PASS' $T/out)" "1
2
0"
chk "cut-off record with exit 0" "$(v cut-rc0; grep -c 'truncated object' $T/out; grep -c '^VERIFY: PASS' $T/out)" "1
1
0"
chk "clean but incomplete listing with exit 0" "$(v one-record-rc0; grep -c 'read 1 objects, the listing has' $T/out; grep -c '^VERIFY: PASS' $T/out)" "1
1
0"
chk "per-object reader exits" "$(r=$(v cat-exit); [ $r != 0 ] && echo nonzero; grep -c '^VERIFY: PASS' $T/out)" "nonzero
0"
chk "no target value printed" "$(cat $T/out | grep -ciE 'aa.bb.cc.dd.ee.01')" 0
tg(){ FAKE=$1 PATH=$T/bin:$PATH python3 -I $S/mac_targets.py $T/orig.git $T/c.txt $T/t.txt > $T/tout 2>&1; echo $?; }
chk "target discovery finds the fixture" "$(tg ''; grep -c 'TARGET' $T/tout)" "0
1"
chk "target discovery stops if its reader exits" "$(tg cat-exit)" 1
echo "failures: $fail"; echo $n; [ $fail = 0 ]
