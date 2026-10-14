#!/bin/bash
# test_v0e_compact.sh — offline tests for v0e_compact.sh (D161): a fake pi on PATH, a fake token counter, temporary
# run base and evidence file. No server, no NPU, no real pi. Usage: bash test_v0e_compact.sh
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p $T/bin
# fake pi: reply with the code word(s) of the files it was asked about; on the second turn write a compaction entry
# unless FAKE_NOCOMPACT=1; FAKE_FAIL_TURN=<n> makes that turn exit 1; FAKE_NORECALL=1: turn 3 gives b.txt's word only. Counts its calls in $T/picalls.
cat > $T/bin/pi <<'EOF'
#!/bin/bash
sd=""; p=""; while [ $# -gt 0 ]; do case $1 in --session-dir) sd=$2; shift;; -p) p=$2; shift;; esac; shift; done
n=$(( $(cat $FAKE_T/picalls 2>/dev/null || echo 0) + 1 )); echo $n > $FAKE_T/picalls
[ "${FAKE_FAIL_TURN:-0}" = $n ] && { echo "error"; exit 1; }
cw() { grep -oE 'CODE-[0-9]+-[A-Z]+' $1 | tail -1; }
echo '{"type":"message","message":{"role":"user"}}' >> $sd/s.jsonl
[ $n = 2 ] && [ "${FAKE_NOCOMPACT:-0}" != 1 ] && echo '{"type":"compaction","summary":"x"}' >> $sd/s.jsonl
case $p in *both*) if [ "${FAKE_NORECALL:-0}" = 1 ]; then cw b.txt; else echo "$(cw a.txt) $(cw b.txt)"; fi;; *a.txt*) cw a.txt;; *b.txt*) cw b.txt;; esac
EOF
chmod +x $T/bin/pi
# fake token counter: FAKE_TOK tokens per file, or a failure when FAKE_TOK=fail
cat > $T/bin/tokc <<'EOF'
#!/bin/bash
[ "$FAKE_TOK" = fail ] && exit 1; echo $FAKE_TOK
EOF
chmod +x $T/bin/tokc
fails=0; i=0
# case <name> <want rc> <want text in the RESULT line> <want pi calls> [VAR=value ...]
case1() { local name=$1 want=$2 text=$3 calls=$4; shift 4; i=$((i+1))
  rm -f $T/picalls; local ev=$T/ev$i.txt
  out=$(cd $T && env PATH=$T/bin:$PATH FAKE_T=$T COMPACT_BASE=$T/base TOKCOUNT=$T/bin/tokc FAKE_TOK=10500 OUT=$T "$@" \
        bash $H/v0e_compact.sh c$i local32k $ev 2>&1); rc=$?
  local got=$(cat $T/picalls 2>/dev/null || echo 0) res=$(grep '^RESULT' $ev | tail -1) ok=1
  [ $rc = $want ] || ok=0; [[ "$res" == *"$text"* ]] || ok=0; [ $got = $calls ] || ok=0
  if [ $name = pass ]; then  # the files: 46,000 characters + the code word line ($RANDOM, 1-5 digits: 11,511-11,515 estimated)
    local a=$T/base/c$i/work/a.txt b=$T/base/c$i/work/b.txt
    [ $(head -c 46000 $a | sha256sum | cut -d' ' -f1) = 7175b3f00d538a1a7b6e3981d6b67a8c3cf02cef22180505fbd69f840dd3b0f4 ] || ok=0
    [ $(head -c 46000 $b | sha256sum | cut -d' ' -f1) = 0c9374db95751e61b832541a75759f494b7d60ff7ff771637e438517a1efaa6d ] || ok=0
    local re1='a\.txt estimate 1151[1-5] real 10500; b\.txt estimate 1151[1-5] real 10500'
    local re2='recall after compaction yes; files estimate 230(2[2-9]|30), real 21000\)'
    [[ "$out" =~ $re1 ]] || ok=0; [[ "$res" =~ $re2 ]] || ok=0
  fi
  if [ $ok = 1 ]; then echo "ok   $name"; else fails=$((fails+1)); echo "FAIL $name (rc $rc, pi calls $got)"; echo "$out" | tail -5; echo "$res"; fi; }
case1 pass 0 "compaction PASS" 3
case1 no-compaction 1 "compaction FAIL (pi turns failed 0/3, compactions 0" 3 FAKE_NOCOMPACT=1
case1 pi-turn-fails 1 "compaction FAIL (pi turns failed 1/3" 3 FAKE_FAIL_TURN=1
# D171: recall after the compaction is gated
case1 recall-missing-fails 1 "compaction FAIL (pi turns failed 0/3, compactions 1, context rejections 0; code words: turn1 yes, turn2 yes, recall after compaction no" 3 FAKE_NORECALL=1
case1 real-too-low 1 "INVALID (precondition: real tokens 16000 outside [16500, 28000])" 0 FAKE_TOK=8000
case1 real-too-high 1 "INVALID (precondition: real tokens 29000 outside [16500, 28000])" 0 FAKE_TOK=14500
case1 real-at-lower-bound 0 "compaction PASS" 3 FAKE_TOK=8250
case1 real-at-upper-bound 0 "compaction PASS" 3 FAKE_TOK=14000
case1 no-token-count 1 "INVALID (precondition: no token count from the server)" 0 FAKE_TOK=fail
mkdir -p $T/lic && cp /usr/share/common-licenses/{GPL-3,GFDL-1.3,LGPL-2.1,MPL-1.1} $T/lic/ && sed -i '1s/^/x/' $T/lic/GPL-3
case1 licence-text-changed 1 "INVALID (precondition: file bodies differ from the frozen sha256)" 0 LICENSES=$T/lic
rm $T/lic/MPL-1.1
case1 licence-missing 1 "INVALID (precondition: licence text missing)" 0 LICENSES=$T/lic
echo "failures: $fails"; exit $fails
