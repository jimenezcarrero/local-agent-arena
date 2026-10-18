#!/bin/bash
# mocked tests for r1_build_master_x86.sh (K2) and r1_models_x86.sh (K3): fake uname/docker/cmake/c++ on PATH, a local
# clone source holding commit af0579c78 (SRC, e.g. a shallow fetch), HOME in a temp dir, synthetic GGUF files (zero
# data) written by a fake llama-quantize. The real gguf_tensor_table.py reads them. No network, no Docker, no board.
# Usage: SRC=<repo with af0579c78 and ff5a2337 (the BUILD_COMMIT cases), each reachable from a branch: a clone of a
#   repo with no refs is empty> bash test_r1_host_scripts.sh
D=$(cd "$(dirname "$0")" && pwd); SRC=${SRC:?SRC=<a git repo holding af0579c78 and ff5a2337>}
COMMIT=af0579c78a07a555d84830d01da7b61cfadbc7ef; ALT=ff5a23376725e5a889fa0bfb987b7541dc304da0
for c in $COMMIT $ALT; do git -C "$SRC" cat-file -e $c || { echo "need $SRC with commit $c"; exit 9; }; done
fails=0
res() {  # res <name> <ok 0/1> <out file>
  if [ "$2" = 1 ]; then echo "ok   $1"; else echo "FAIL $1"; tail -6 "$3" | sed 's/^/     /'; fails=$((fails+1)); fi; }

# ---------- synthetic GGUF writer (used by the fake llama-quantize and for the BF16 source) ----------
GEN=$(mktemp -d)/gen.py; export GEN; trap 'rm -rf "$(dirname "$GEN")"' EXIT   # every case removes its own T
cat > $GEN <<'PY'
import struct, sys
# gen.py <path> <arch> <expert type> <other type>: 40 blocks, an expert tensor triple per block, a tied embedding
TID = {"F32": 0, "Q8_0": 8, "Q2_K": 10, "Q3_K": 11, "Q5_0": 6, "BF16": 30}
BS = {"F32": (1, 4), "Q8_0": (32, 34), "Q2_K": (256, 84), "Q3_K": (256, 110), "Q5_0": (32, 22), "BF16": (1, 2)}
path, arch, ext, oth = sys.argv[1:5]
s = lambda x: struct.pack("<Q", len(x.encode())) + x.encode()
arr = lambda v: struct.pack("<IQ", 4, len(v)) + struct.pack(f"<{len(v)}I", *v)
kvs = [("general.architecture", 8, s(arch)), (f"{arch}.block_count", 4, struct.pack("<I", 40)),
       (f"{arch}.attention.head_count_kv", 9, arr([2 if i % 4 == 2 else 0 for i in range(40)])),
       (f"{arch}.attention.head_count", 4, struct.pack("<I", 4)), (f"{arch}.embedding_length", 4, struct.pack("<I", 256))]
ts = [("token_embd.weight", (256, 64), oth), ("token_embd_norm.weight", (256,), "F32")]
for i in range(40):
    ts += [(f"blk.{i}.attn_norm.weight", (256,), "F32")] + [(f"blk.{i}.ffn_{w}_exps.weight", (256, 32, 4), ext) for w in ("gate", "up", "down")]
out = b"GGUF" + struct.pack("<IQQ", 3, len(ts), len(kvs))
for k, t, v in kvs:
    out += s(k) + struct.pack("<I", t) + v
off, data = 0, b""
for name, dims, ty in ts:
    out += s(name) + struct.pack("<I", len(dims)) + struct.pack("<" + "Q" * len(dims), *dims) + struct.pack("<IQ", TID[ty], off)
    n = 1
    for d in dims: n *= d
    nb = n // BS[ty][0] * BS[ty][1]; pad = (nb + 31) // 32 * 32; data += b"\0" * pad; off += pad
out += b"\0" * ((32 - len(out) % 32) % 32)
open(path, "wb").write(out + data)
PY

mkfakes() {  # mkfakes <dir>; modes in $T/<name> files
  mkdir -p "$1"
  printf '#!/bin/bash\n[ "$1" = -m ] && cat $T/arch || /usr/bin/uname "$@"\n' > "$1/uname"
  cat > "$1/docker" <<'EOF'
#!/bin/bash
case $1 in
  info|pull) exit 0;;
  --version) echo "Docker version fake"; exit 0;;
  image) cat $T/imageid; exit 0;;
  run) args="$*"
    if [[ $args != *cmake* ]]; then
      case $(cat $T/tc) in
        ok) printf 'HEXAGON_SDK_ROOT=/opt/hexagon/6.6.0.0\nHEXAGON_TOOLS_ROOT=/opt/hexagon/6.6.0.0/tools/HEXAGON_Tools/19.0.07\nQuIC LLVM Hexagon Clang version 19.0.07\n'; exit 0;;
        wrongsdk) printf 'HEXAGON_SDK_ROOT=/opt/hexagon/6.4.0.2\nHEXAGON_TOOLS_ROOT=/opt/hexagon/6.4.0.2/tools/HEXAGON_Tools/19.0.04\nclang version 19\n'; exit 0;;
        *) echo "hexagon-clang: No such file or directory"; exit 1;;
      esac
    fi
    [ "$(cat $T/buildrc)" = 0 ] || { echo "make: *** error"; exit 2; }
    w=$(grep -oE -- '-v [^:]+:/workspace' <<< "$args" | sed -n '1{s/^-v //;s/:\/workspace$//;p}')
    p=$(grep -oE -- '--prefix [^ "]+' <<< "$args" | sed 's/--prefix //')
    [ "$(cat $T/sdkline)" = yes ] && echo "-- hexagon: using /opt/hexagon/6.6.0.0 and /opt/hexagon/6.6.0.0/tools/HEXAGON_Tools/19.0.07 for building libggml-htp skels"
    seq 1 100000 | sed 's/^/-- build line /'
    cp $w/docs/backend/snapdragon/CMakeUserPresets.json $w/
    mkdir -p $w/$p/bin $w/$p/lib $w/build-snapdragon
    elf=$( [ "$(cat $T/elf)" = aarch64 ] && printf '\xb7' || printf '\x3e' )
    for b in llama-server llama-cli llama-bench llama-perplexity llama-quantize; do
      { printf '\x7fELF\x02\x01\x01\0\0\0\0\0\0\0\0\0\x02\0'; printf "$elf"; printf '\0rest'; } > $w/$p/bin/$b; done
    for l in libggml-hexagon.so libggml-htp-v75.so libggml-htp-v79.so; do echo "lib $l" > $w/$p/lib/$l; done
    [ "$(cat $T/htp)" = yes ] || rm $w/$p/lib/libggml-htp-v75.so
    f=$(cat $T/flags)
    printf 'CMAKE_C_FLAGS:STRING=%s -fvectorize\nCMAKE_CXX_FLAGS:STRING=%s -fvectorize\nCMAKE_C_FLAGS_RELEASE:STRING=-O3\n' "$f" "$f" > $w/build-snapdragon/CMakeCache.txt
    exit 0;;
esac; exit 1
EOF
  cat > "$1/cmake" <<'EOF'
#!/bin/bash
[ "$1" = --version ] && { echo "cmake version 3.99-fake"; exit 0; }
if [ "$1" = -S ]; then mkdir -p build-host; printf 'CMAKE_BUILD_TYPE:STRING=Release\nCMAKE_C_COMPILER:FILEPATH=%s/cc\nCMAKE_CXX_COMPILER:FILEPATH=%s/c++\nGGML_NATIVE:BOOL=OFF\n' "$T/bin" "$T/bin" > build-host/CMakeCache.txt; echo "-- configured"; exit 0; fi
[ "$(cat $T/hostbuild)" = ok ] || { echo "error: compiler"; exit 1; }
mkdir -p build-host/bin
printf '#!/bin/bash\n# fake llama-quantize <src> <dst> <type> <n>\n[ "$(cat $T/qrc)" = 0 ] || exit 1\ncase $3 in Q8_0) e=Q8_0;; Q2_K) e=$(cat $T/m2exp);; esac\npython3 %s "$2" lfm2moe $e $3\necho "llama_model_quantize_impl: model size = fake"\n' "$GEN" > build-host/bin/llama-quantize
printf '#!/bin/bash\nexit 0\n' > build-host/bin/llama-perplexity; echo "fake lib" > build-host/bin/libllama.so
chmod +x build-host/bin/*; echo "[100%] Built target llama-quantize"; exit 0
EOF
  printf '#!/bin/bash\necho Avail; cat $T/free\n' > "$1/df"   # bytes available, from the case
  printf '#!/bin/bash\necho "c++ (fake) 13.0"\n' > "$1/c++"; printf '#!/bin/bash\necho "cc (fake) 13.0"\n' > "$1/cc"
  chmod +x "$1"/*; }

setup() {  # setup <kv>...: defaults then overrides; fresh T
  T=$(mktemp -d); export T; mkdir -p $T/home
  for kv in arch=x86_64 imageid=sha256:41b710ee5f99d21f0fb9d83a1f815ecffb7708315b4218a11cd0baeb5ecf4c14 tc=ok buildrc=0 \
            sdkline=yes elf=aarch64 htp=yes free=1099511627776 "flags=-march=armv8.2a+fp16+dotprod" hostbuild=ok qrc=0 m2exp=Q2_K "$@"; do
    echo "${kv#*=}" > $T/${kv%%=*}; done
  mkfakes $T/bin; }

# ---------------- K2 ----------------
k2() {  # k2 <name> <want ok|fail> [mode=value ...]
  local name=$1 want=$2; shift 2; setup "$@"
  HOME=$T/home PATH=$T/bin:$PATH REPO_URL=file://$SRC bash "$D/r1_build_master_x86.sh" > $T/out.txt 2>&1; local rc=$?
  local tars=$(ls $T/home/pkg-unpatched-af0579c7-*.tar.gz 2>/dev/null | wc -l) ok=1
  if [ $want = ok ]; then
    [ $rc = 0 ] && [ $tars = 1 ] && grep -qx DONE $T/out.txt || ok=0
    local tl=$(tar tzf $T/home/pkg-unpatched-af0579c7-*.tar.gz 2>/dev/null)
    grep -qx manifest.txt <<< "$tl" && grep -qx pkg-unpatched-af0579c7.sha256 <<< "$tl" && grep -qx compile-flags.txt <<< "$tl" \
      && grep -q '^pkg-unpatched-af0579c7/lib/libggml-htp-v75.so$' <<< "$tl" || ok=0
    local man=$(tar xzf $T/home/pkg-unpatched-af0579c7-*.tar.gz -O manifest.txt 2>/dev/null)
    grep -q "^source: ggml-org/llama.cpp $COMMIT" <<< "$man" && grep -q "not copied to the board" <<< "$man" \
      && grep -q "march=armv8.2a+fp16+dotprod" <<< "$man" || ok=0
  else [ $rc != 0 ] && [ $rc != 141 ] && [ $tars = 0 ] && ! grep -qx DONE $T/out.txt || ok=0; fi
  [ -n "${WANT_MSG:-}" ] && { grep -qF "$WANT_MSG" $T/out.txt || ok=0; }
  res "K2 $name (rc $rc)" $ok $T/out.txt
  [ $name = normal ] || rm -rf "$T"
  [ $name = normal ] && { sleep 1; HOME=$T/home PATH=$T/bin:$PATH REPO_URL=file://$SRC bash "$D/r1_build_master_x86.sh" > $T/out2.txt 2>&1
    [ $? = 0 ] && [ $(ls -d $T/home/r1-k2-2* | wc -l) = 2 ] && [ $(ls $T/home/pkg-unpatched-*.tar.gz | wc -l) = 2 ]
    res "K2 a second run makes its own directory and tarball, the first kept" $([ $? = 0 ] && echo 1 || echo 0) $T/out2.txt; rm -rf "$T"; }
}
k2 normal ok
WANT_MSG="not x86_64" k2 not-x86 fail arch=aarch64
# BUILD_COMMIT (review of 687d862): another pinned commit with its checked date; wrong, malformed or missing dates refused
k2alt() {  # k2alt <name> <want ok|fail> <BUILD_COMMIT> <BUILD_COMMIT_DATE or -unset> [msg]
  local name=$1 want=$2 bc=$3 bd=$4 msg=${5:-}; setup
  if [ "$bd" = -unset ]; then HOME=$T/home PATH=$T/bin:$PATH REPO_URL=file://$SRC BUILD_COMMIT=$bc bash "$D/r1_build_master_x86.sh" > $T/out.txt 2>&1
  else HOME=$T/home PATH=$T/bin:$PATH REPO_URL=file://$SRC BUILD_COMMIT=$bc BUILD_COMMIT_DATE=$bd bash "$D/r1_build_master_x86.sh" > $T/out.txt 2>&1; fi
  local rc=$? ok=1 tars=$(ls $T/home/pkg-unpatched-*.tar.gz 2>/dev/null | wc -l)
  if [ $want = ok ]; then
    [ $rc = 0 ] && [ $(ls $T/home/pkg-unpatched-${bc:0:8}-*.tar.gz 2>/dev/null | wc -l) = 1 ] || ok=0
    tar xzf $T/home/pkg-unpatched-${bc:0:8}-*.tar.gz -O manifest.txt 2>/dev/null | grep -q "^source: ggml-org/llama.cpp $bc (master, $bd;" || ok=0
  else [ $rc != 0 ] && [ $tars = 0 ] || ok=0; [ -z "$msg" ] || grep -qF "$msg" $T/out.txt || ok=0; fi
  res "K2 $name (rc $rc)" $ok $T/out.txt; rm -rf "$T"; }
k2alt alt-commit-with-its-date ok $ALT 2026-10-18T17:48:47Z
k2alt alt-commit-wrong-date fail $ALT 2026-10-18T17:48:48Z "committer date is 2026-10-18T17:48:47Z"
k2alt alt-commit-malformed-date fail $ALT yesterday "must be the committer date in UTC"
k2alt alt-commit-no-date fail $ALT -unset "BUILD_COMMIT needs BUILD_COMMIT_DATE"
k2alt short-sha fail ff5a2337 2026-10-18T17:48:47Z "full 40-hex sha"
WANT_MSG="image id sha256:0000" k2 wrong-image fail imageid=sha256:0000
WANT_MSG="toolchain provenance not captured" k2 toolchain-missing fail tc=fail
WANT_MSG="image SDK root is not" k2 wrong-sdk fail tc=wrongsdk
WANT_MSG="build failed (rc=2)" k2 build-fails fail buildrc=2
WANT_MSG="build log does not name the SDK/tools" k2 no-sdk-line fail sdkline=no
WANT_MSG="not an aarch64 ELF" k2 not-aarch64-elf fail elf=x86
WANT_MSG="libggml-htp-v75.so missing" k2 no-htp-v75 fail htp=no
WANT_MSG="flags name i8mm" k2 flags-i8mm fail "flags=-march=armv8.2a+fp16+dotprod+i8mm"
WANT_MSG="flags are not -march=armv8.2a+fp16+dotprod" k2 flags-other fail "flags=-march=armv8-a"

# ---------------- K3 ----------------
k3() {  # k3 <name> <want ok|fail> <bf16 mode: path|url> [mode=value ...]; BF16 file from $BF (env BFX to replace)
  local name=$1 want=$2 how=$3; shift 3; setup "$@"
  local bf=$T/src/LFM2.5-24B-A2B-BF16.gguf; mkdir -p $T/src; python3 $GEN $bf ${BFARCH:-lfm2moe} BF16 BF16
  local size=${BFSIZE:-$(stat -c %s $bf)} sha=${BFSHA:-$(sha256sum $bf | cut -d' ' -f1)}
  local tsha=${TSHA:-$(sha256sum $D/gguf_tensor_table.py | cut -d' ' -f1)}
  local env=(HOME=$T/home PATH=$T/bin:$PATH REPO_URL=file://$SRC BF16_SIZE=$size BF16_SHA=$sha TABLE_URL=file://$D/gguf_tensor_table.py
             TABLE_SHA=$tsha BF16_URL=file://$bf)
  local R=$((36 * 1024**3)) part=1000000   # the script's reserve; the size of a prepared .part
  case ${FREE:-} in  # free bytes for the disk admission (default 1 TiB); the real guard, no bypass
    exact) echo $R > $T/free;; short) echo $((R - 1)) > $T/free;;
    exact-part) echo $((R + size - part)) > $T/free;; short-part) echo $((R + size - part - 1)) > $T/free;;
    short-new) echo $((R + size - 1)) > $T/free;; exact-new) echo $((R + size)) > $T/free;;
  esac
  [ $how = path ] && env+=(BF16=$bf)
  if [ $how = relpath ]; then mkdir -p "$T/my models"; cp $bf "$T/my models/"; env+=("BF16=my models/$(basename $bf)"); fi
  mkdir -p $T/home/r1-downloads
  [ $how = part ] && head -c $part $bf > $T/home/r1-downloads/$(basename $bf).part
  [ $how = badpart ] && { head -c $part /dev/urandom > $T/home/r1-downloads/$(basename $bf).part; }
  [ $how = done ] && cp $bf $T/home/r1-downloads/
  (cd $T && env "${env[@]}" bash "$D/r1_models_x86.sh" > $T/out.txt 2>&1); local rc=$?
  local tars=$(ls $T/home/r1-k3-evidence-*.tar.gz 2>/dev/null | wc -l) ok=1
  if [ $want = ok ]; then
    local man=$(tar xzf $T/home/r1-k3-evidence-*.tar.gz -O evidence/manifest.txt 2>/dev/null)
    [ $rc = 0 ] && [ $tars = 1 ] && grep -qx DONE $T/out.txt || ok=0
    grep -q "^TEST RUN with overridden sources: NOT EVIDENCE" <<< "$man" && grep -q "LFM2.5-24B-A2B-M2-Q2_K-af0579c7.gguf bytes" <<< "$man" \
      && grep -q "LFM2.5-24B-A2B-REF-Q8_0-af0579c7.gguf bytes" <<< "$man" && grep -q "expert tensors: 120, not an NPU type: 0" <<< "$man" \
      && grep -q "EXPLICIT weights + KV" <<< "$man" && grep -q "TIED output on the CPU" <<< "$man" || ok=0
    ! tar tzf $T/home/r1-k3-evidence-*.tar.gz | grep -q '\.gguf$' || ok=0   # no model in the evidence
    grep -q "CMAKE_CXX_COMPILER $T/bin/c++: c++ (fake) 13.0" <<< "$man" && grep -qE '^host toolchain: [0-9a-f]{64}  ./llama-quantize$' <<< "$man" \
      && grep -qE '^host toolchain: [0-9a-f]{64}  ./libllama.so$' <<< "$man" || ok=0
    case $how in
      path) [ ! -e $T/home/r1-downloads/LFM2.5-24B-A2B-BF16.gguf ] && grep -q "(existing copy, checked)" <<< "$man" || ok=0;;
      relpath) grep -qF "BF16: $T/my models/LFM2.5-24B-A2B-BF16.gguf bytes" <<< "$man" || ok=0;;
      *) [ -s $T/home/r1-downloads/LFM2.5-24B-A2B-BF16.gguf ] && [ ! -e $T/home/r1-downloads/LFM2.5-24B-A2B-BF16.gguf.part ] || ok=0;;
    esac
  else [ $rc != 0 ] && [ $tars = 0 ] && ! grep -qx DONE $T/out.txt || ok=0; fi
  [ $how = badpart ] && { [ ! -e $T/home/r1-downloads/LFM2.5-24B-A2B-BF16.gguf ] || ok=0; }   # never promoted
  [ -n "${WANT_MSG:-}" ] && { grep -qF "$WANT_MSG" $T/out.txt || ok=0; }
  res "K3 $name (rc $rc)" $ok $T/out.txt
  rm -rf "$T"
}
k3 existing-bf16 ok path
k3 downloaded-bf16 ok url
WANT_MSG="using the existing" k3 relative-bf16-path-with-spaces ok relpath
WANT_MSG="resuming" k3 download-resumes-an-earlier-part ok part
WANT_MSG="reusing the earlier complete download" k3 complete-download-reused ok done
WANT_MSG=".part and rerun" k3 corrupt-earlier-part-fails-the-hash-before-promotion fail badpart
BFSHA=$(printf 0%.0s {1..64}) WANT_MSG="sha256" k3 bf16-sha-differs fail path
BFSIZE=123 WANT_MSG="bytes, expected 123" k3 bf16-size-differs fail url
TSHA=$(printf 1%.0s {1..64}) WANT_MSG="gguf_tensor_table.py sha256 differs" k3 table-tool-sha-differs fail path
BFARCH=llama WANT_MSG="BF16 header is not lfm2moe" k3 bf16-not-lfm2moe fail path
WANT_MSG="an expert tensor is not an NPU type" k3 m2-expert-not-npu-type fail path m2exp=Q5_0
# disk admission by source (review of 17130d9): the 36 GiB reserve plus what is still to download
FREE=exact WANT_MSG="BF16 source: existing copy" k3 disk-existing-copy-needs-only-the-reserve ok path
FREE=short WANT_MSG="need 36.0" k3 disk-existing-copy-short-by-one-byte fail path
FREE=exact WANT_MSG="BF16 source: complete cached download" k3 disk-complete-cache-needs-only-the-reserve ok done
FREE=short WANT_MSG="0.0 GiB still to download" k3 disk-complete-cache-short-by-one-byte fail done
FREE=exact-part WANT_MSG="BF16 source: partial cached download" k3 disk-partial-cache-needs-the-remainder ok part
FREE=short-part WANT_MSG="still to download" k3 disk-partial-cache-short-by-one-byte fail part
FREE=exact-new WANT_MSG="BF16 source: a new download" k3 disk-new-download-needs-the-whole-size ok url
FREE=short-new WANT_MSG="BF16 source: a new download" k3 disk-new-download-short-by-one-byte fail url
WANT_MSG="not x86_64" k3 not-x86 fail path arch=aarch64
WANT_MSG="host build failed" k3 host-build-fails fail path hostbuild=fail
WANT_MSG="REF quantize failed" k3 quantize-fails fail path qrc=1
echo "failures: $fails"; exit $fails
