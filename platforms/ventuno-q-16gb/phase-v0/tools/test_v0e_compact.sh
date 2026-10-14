#!/bin/bash
# test_v0e_compact.sh — offline tests for v0e_compact.sh (D161): a fake pi on PATH, a fake token counter, temporary
# run base and evidence file. No server, no NPU, no real pi. Usage: bash test_v0e_compact.sh
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p $T/bin
# fake pi (D172: writes session entries in pi 0.80.10's format, as in the A32-3 session: user/assistant/toolResult
# messages with text, thinking and toolCall parts, a compaction entry). Turns 1 and 2 read the file and answer with its
# code word; a compaction entry follows turn 2 unless FAKE_NOCOMPACT=1; FAKE_FAIL_TURN=<n> makes that turn exit 1.
# FAKE_T3 sets turn 3: good (both words in the text) | norecall (b.txt's word only) | toolwords (a tool prints the
# words, the answer recalls neither) | thinkwords (both words only in the thinking part) | reread (reads a.txt again,
# then both words) | late (the compaction entry after turn 3's prompt). Every mode prints both words to stdout, so
# stdout alone never decides. Counts its calls in $T/picalls.
cat > $T/bin/pi <<'EOF'
#!/usr/bin/env python3
import json, os, re, sys
a = sys.argv[1:]; sd, p = a[a.index("--session-dir") + 1], a[a.index("-p") + 1]; T = os.environ["FAKE_T"]
n = int(open(T + "/picalls").read()) + 1 if os.path.exists(T + "/picalls") else 1
open(T + "/picalls", "w").write(str(n))
if os.environ.get("FAKE_FAIL_TURN") == str(n):
    print("error"); sys.exit(1)
cw = lambda f: re.findall(r"CODE-\d+-[A-Z]+", open(f).read())[-1]
f = open(os.path.join(sd, "s.jsonl"), "a")
w = lambda e: f.write(json.dumps(e, separators=(",", ":")) + "\n")  # compact, as pi writes it
msg = lambda role, *parts: w({"type": "message", "message": {"role": role, "content": list(parts)}})
txt = lambda t: {"type": "text", "text": t}
def read(name):
    msg("assistant", {"type": "toolCall", "id": f"c{n}", "name": "read", "arguments": {"path": name}})
    msg("toolResult", txt(open(name).read()[-300:]))
mode = os.environ.get("FAKE_T3", "good"); w1, w2 = cw("a.txt"), cw("b.txt")
if n < 3 or mode != "late":
    msg("user", txt(p))
if n == 1:
    read("a.txt"); msg("assistant", txt(w1))
elif n == 2:
    read("b.txt"); msg("assistant", txt(w2))
    if os.environ.get("FAKE_NOCOMPACT") != "1" and mode != "late":
        w({"type": "compaction", "summary": "x"})
elif mode == "late":
    msg("user", txt(p)); w({"type": "compaction", "summary": "x"}); msg("assistant", txt(f"{w1} {w2}"))
elif mode == "good":
    msg("assistant", {"type": "thinking", "thinking": "recall"}, txt(f"{w1} {w2}"))
elif mode == "norecall":
    msg("assistant", txt(w2))
elif mode == "toolwords":
    msg("assistant", {"type": "toolCall", "id": "c9", "name": "bash", "arguments": {"command": "tail -1 a.txt b.txt"}})
    msg("toolResult", txt(f"{w1}\n{w2}")); msg("assistant", txt("I cannot recall either word."))
elif mode == "thinkwords":
    msg("assistant", {"type": "thinking", "thinking": f"{w1} {w2}"}, txt("I do not remember them."))
elif mode == "reread":
    read("a.txt"); msg("assistant", txt(f"{w1} {w2}"))
print(f"{w1} {w2}" if n == 3 else (w1 if n == 1 else w2))
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
case1 recall-missing-fails 1 "recall after compaction no (final answer has 1 of 2 code words)" 3 FAKE_T3=norecall
# D172 (Codex review of 370f7a2): recall is read from turn 3's final answer in the session file, after the compaction
case1 words-only-in-tool-output-fails 1 "recall after compaction no (a tool was used in turn 3)" 3 FAKE_T3=toolwords
case1 words-only-in-thinking-fails 1 "recall after compaction no (final answer has 0 of 2 code words)" 3 FAKE_T3=thinkwords
case1 reread-after-compaction-fails 1 "recall after compaction no (a tool was used in turn 3)" 3 FAKE_T3=reread
case1 compaction-after-turn3-prompt-fails 1 "recall after compaction no (no compaction before turn 3)" 3 FAKE_T3=late
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
