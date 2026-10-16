#!/bin/bash
# mocked tests for r1_t7_x86.sh (T7): fake uname (x86_64) and cmake on PATH; the fake build writes a fake
# llama-perplexity (synthetic logits files in llama-perplexity's format, and its KL-divergence report with values set by
# the case) and a fake llama-server (a loopback HTTP server answering the T5 requests, correct or not as the case
# says); a fake c++ compiles the real comparator with the real compiler and replaces the token tool with one writing
# synthetic tokens. Companion files, the text zip and the repository come from local paths (file:// and a local clone
# holding af0579c78), so no network. Models are small synthetic files with their own sizes and hashes.
# Usage: SRC=<repo with af0579c78> bash test_r1_t7_x86.sh
D=$(cd "$(dirname "$0")" && pwd); ND=$(cd "$D/.." && pwd); SRC=${SRC:?SRC=<a git repo holding af0579c78>}
COMMIT=af0579c78a07a555d84830d01da7b61cfadbc7ef
git -C "$SRC" cat-file -e $COMMIT || { echo "need $SRC with commit $COMMIT"; exit 9; }
REALCXX=$(command -v c++); PY=$(command -v python3)
fails=0
res() { if [ "$2" = 1 ]; then echo "ok   $1"; else echo "FAIL $1"; tail -6 "$3" | sed 's/^/     /'; fails=$((fails+1)); fi; }

setup() {  # a fresh temp HOME, fake tools, synthetic inputs; echoes the temp dir
  local T; T=$(mktemp -d); mkdir -p "$T/home" "$T/bin" "$T/src" "$T/models"
  cat > "$T/bin/uname" <<'EOF'
#!/bin/bash
[ "${1:-}" = -m ] && { echo x86_64; exit 0; }; exec /usr/bin/uname "$@"
EOF
  cat > "$T/bin/cmake" <<EOF
#!/bin/bash
if [ "\${1:-}" = --version ]; then echo "cmake version 0.0-fake"; exit 0; fi
if [ "\${1:-}" = --build ]; then
  mkdir -p build-host/bin; cp "$T/fakeppl" build-host/bin/llama-perplexity; cp "$T/fakeserver" build-host/bin/llama-server
  chmod +x build-host/bin/*; exit 0; fi
mkdir -p build-host; printf 'CMAKE_C_COMPILER:FILEPATH=/usr/bin/cc\nCMAKE_CXX_COMPILER:FILEPATH=/usr/bin/c++\nCMAKE_BUILD_TYPE:STRING=Release\nGGML_NATIVE:BOOL=ON\n' > build-host/CMakeCache.txt
EOF
  cat > "$T/bin/c++" <<EOF
#!/bin/bash
out=; for ((i=1; i<=\$#; i++)); do [ "\${!i}" = -o ] && { j=\$((i+1)); out=\${!j}; }; done
case "\$out" in
  */r1_t7_tokens) printf '#!/bin/bash\nexec $PY -I $T/faketok.py "\$@"\n' > "\$out"; chmod +x "\$out";;
  *) exec $REALCXX "\$@";;
esac
EOF
  # synthetic tokens: n_chunk x n_ctx ids (the test's TOK_SHA is their sha256)
  cat > "$T/faketok.py" <<'EOF'
import struct, sys
model, text, n_ctx, n_chunk, out = sys.argv[1:6]; n = int(n_ctx) * int(n_chunk)
open(out, "wb").write(struct.pack(f"<{n}i", *[(i * 7 + 3) % 11 for i in range(n)])); print(f"tokens {n}, add_bos 1")
EOF
  # fake llama-perplexity: base mode writes a logits file; --kl-divergence prints the report lines (values from env)
  cat > "$T/fakeppl.py" <<'EOF'
import math, os, random, struct, sys
a = sys.argv[1:]; g = lambda k: a[a.index(k) + 1] if k in a else None
n_ctx, n_chunk, model = int(g("-c")), int(g("--chunks")), g("-m"); n_vocab = 11
nv = 2 * ((n_vocab + 1) // 2) + 4; rows = (n_ctx - 1 - n_ctx // 2) * n_chunk
if "--kl-divergence" in a:
    print("====== KL divergence statistics ======")
    print(f"Mean    KLD: {os.environ.get('FAKE_MEAN', '0.050000')} ±   0.001000")
    print(f"99.0%   KLD: {os.environ.get('FAKE_P99', '0.500000')}")
    print(f"Same top p: {os.environ.get('FAKE_TOP1', '93.500')} ± 0.200 %"); sys.exit(0)
toks = [(i * 7 + 3) % 11 for i in range(n_ctx * n_chunk)]
if os.environ.get("FAKE_BADTOK") and "M2" in os.path.basename(model): toks[5] = 0 if toks[5] else 1
random.seed(1 if "REF" in os.path.basename(model) else 2)
with open(g("--kl-divergence-base"), "wb") as f:
    f.write(b"_logits_" + struct.pack("<Iii", n_ctx, n_vocab, n_chunk) + struct.pack(f"<{len(toks)}i", *toks))
    for _ in range(rows):
        q = [random.randrange(65536) for _ in range(n_vocab)]
        f.write(struct.pack("<ff", 0.0002, -14.0) + struct.pack(f"<{n_vocab}H", *q) + b"\0" * 2 * (nv - 4 - n_vocab))
EOF
  printf '#!/bin/bash\nexec %s -I %s "$@"\n' "$PY" "$T/fakeppl.py" > "$T/fakeppl"
  # fake llama-server: correct calls except FAKE_WRONG_<label> first requests; FAKE_CACHED makes trials non-fresh
  cat > "$T/fakeserver.py" <<'EOF'
import http.server, json, os, sys
a = sys.argv[1:]; port = int(a[a.index("--port") + 1]); model = os.path.basename(a[a.index("-m") + 1])
label = "REF" if "REF" in model else "M2"; wrong = int(os.environ.get(f"FAKE_WRONG_{label}", "0"))
doc = json.load(open(os.environ["FAKE_REQ"]))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *x): pass
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"ok"}')
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = json.loads(self.rfile.read(n) or b"null")
        if self.path.startswith("/slots/"):
            self.send_response(200); self.end_headers(); self.wfile.write(b"{}"); return
        user = body["messages"][1]["content"]; idx = [r["user"] for r in doc["requests"]].index(user); e = doc["requests"][idx]["expected"]
        props = next(t["function"]["parameters"]["properties"] for t in doc["tools"] if t["function"]["name"] == e["tool"])
        args = {k: v for k, (m, v) in e["values"].items()}
        for k in props: args.setdefault(k, "x")
        name = "search_web" if idx < wrong else e["tool"]
        resp = {"choices": [{"message": {"tool_calls": [{"id": "c1", "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}]}}],
                "usage": {"prompt_tokens": 400}, "timings": {"cache_n": 50 if os.environ.get("FAKE_CACHED") else 0, "prompt_n": 400}}
        out = json.dumps(resp).encode(); self.send_response(200); self.end_headers(); self.wfile.write(out)
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
  printf '#!/bin/bash\nexec %s -I %s "$@"\n' "$PY" "$T/fakeserver.py" > "$T/fakeserver"
  chmod +x "$T/bin/"* "$T/fakeppl" "$T/fakeserver"
  # companion files at local paths, the text zip, models
  mkdir -p "$T/tb/tools" "$T/tb/k5-t7"
  cp "$D/r1_t7_compare.cpp" "$D/r1_t5_screen.py" "$D/r1_t7_tokens.cpp" "$T/tb/tools/"; cp "$ND/k5-t7/t5-requests.json" "$T/tb/k5-t7/"
  $PY -I -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("wikitext-2-raw/wiki.test.raw", "text " * 100); z.close()' "$T/wt.zip"
  head -c 3000 /dev/urandom > "$T/models/M2.gguf"; head -c 5000 /dev/urandom > "$T/models/REF.gguf"
  echo "$T"
}

run_case() {  # <T> [VAR=value ...]: runs the script with the test pins; output in $T/out, rc in $T/rc
  local T=$1; shift
  local ztok; ztok=$($PY -I -c 'import hashlib, struct; n = 64 * 3; print(hashlib.sha256(struct.pack(f"<{n}i", *[(i * 7 + 3) % 11 for i in range(n)])).hexdigest())')
  local zwt; zwt=$($PY -I -c 'import hashlib, sys, zipfile; print(hashlib.sha256(zipfile.ZipFile(sys.argv[1]).read("wikitext-2-raw/wiki.test.raw")).hexdigest())' "$T/wt.zip")
  env -i HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" FAKE_REQ="$T/tb/k5-t7/t5-requests.json" \
    REPO_URL="$SRC" TOOLS_BASE="file://$T/tb" WT_URL="file://$T/wt.zip" WT_ZIP_SHA="$(sha256sum "$T/wt.zip" | cut -d' ' -f1)" \
    WT_TEST_SHA="$zwt" TOK_SHA="$ztok" N_CTX=64 N_CHUNK=3 MIN_FREE_GIB=1 PORT=$((20000 + RANDOM % 20000)) \
    M2="$T/models/M2.gguf" REF="$T/models/REF.gguf" M2_SIZE=3000 REF_SIZE=5000 \
    M2_SHA="$(sha256sum "$T/models/M2.gguf" | cut -d' ' -f1)" REF_SHA="$(sha256sum "$T/models/REF.gguf" | cut -d' ' -f1)" \
    CMP_SHA="$(sha256sum "$D/r1_t7_compare.cpp" | cut -d' ' -f1)" SCREEN_SHA="$(sha256sum "$D/r1_t5_screen.py" | cut -d' ' -f1)" \
    REQ_SHA="$(sha256sum "$ND/k5-t7/t5-requests.json" | cut -d' ' -f1)" TOKTOOL_SHA="$(sha256sum "$D/r1_t7_tokens.cpp" | cut -d' ' -f1)" \
    "$@" bash "$D/r1_t7_x86.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
verdict() { sed -n 's/^T7 VERDICT: //p' "$1/out" | tail -1; }
case_() {  # <name> <want rc> <want verdict prefix or -> [VAR=value ...]
  local name=$1 want_rc=$2 want_v=$3; shift 3
  local T; T=$(setup); run_case "$T" "$@"
  local rc v; rc=$(cat "$T/rc"); v=$(verdict "$T")
  local okk=0 why; why=$(grep -m1 '^FAILED: ' "$T/out" | cut -c1-90)
  if [ "$want_v" = - ] || [ "${want_v#FAILED:}" != "$want_v" ]; then   # an invalid run: its own FAILED reason, no verdict
    [ "$rc" = "$want_rc" ] && ! grep -q '^T7 VERDICT' "$T/out" && { [ "$want_v" = - ] || grep -qF "$want_v" "$T/out"; } && okk=1
  else
    [ "$rc" = "$want_rc" ] && [ "${v#"$want_v"}" != "$v" ] && okk=1
  fi
  res "$name (rc $rc, verdict '${v:-none}'${why:+, $why})" $okk "$T/out"
  [ "$want_rc" = 0 ] && [ "$okk" = 1 ] && { ls "$T"/home/r1-t7-evidence-*.tar.gz >/dev/null 2>&1 || { echo "FAIL $name: no evidence tarball"; fails=$((fails+1)); }; }
  rm -rf "$T"
}
case_ "all good: PASS, evidence written" 0 PASS
case_ "top-1 exactly 90.000: PASS (boundary)" 0 PASS FAKE_TOP1=90.000
case_ "top-1 89.999: FAIL" 0 "FAIL: top-1" FAKE_TOP1=89.999
case_ "M2 T5 16/20: FAIL" 0 "FAIL: M2 T5 passes 16/20" FAKE_WRONG_M2=4
case_ "M2 17/20, REF 20/20 (REF - 3): FAIL" 0 "FAIL: M2 T5 passes 17 < REF" FAKE_WRONG_M2=3
case_ "M2 18/20, REF 20/20 (REF - 2): PASS (boundary)" 0 PASS FAKE_WRONG_M2=2
case_ "M2 17/20, REF 19/20: PASS" 0 PASS FAKE_WRONG_M2=3 FAKE_WRONG_REF=1
case_ "non-finite mean KLD: invalid run (no verdict)" 1 "FAILED: a KL-divergence statistic is missing or not finite" FAKE_MEAN=nan
case_ "missing top-1 line value: invalid run" 1 "FAILED: a KL-divergence statistic is missing or not finite" FAKE_TOP1=
case_ "T5 trial not fresh: invalid run" 1 "FAILED: T5 run (REF) invalid" FAKE_CACHED=1
case_ "logits files with different tokens: comparator rejects, invalid run" 1 "FAILED: comparator rejected the logits files" FAKE_BADTOK=1
case_ "M2 sha256 mismatch: invalid run" 1 "FAILED: M2 sha256 differs" M2_SHA=0000
case_ "REF size mismatch: invalid run" 1 "FAILED: REF is 5000 bytes, expected 4999" REF_SIZE=4999
case_ "companion file sha256 mismatch: invalid run" 1 "FAILED: tools/r1_t5_screen.py sha256 differs" SCREEN_SHA=0000
case_ "token pin mismatch: invalid run" 1 "FAILED: M2's tokens differ from the pinned" TOK_SHA=0000
case_ "text sha256 mismatch: invalid run" 1 "FAILED: wiki.test.raw sha256 differs" WT_TEST_SHA=0000
echo "failures: $fails"; exit $fails
