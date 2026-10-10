#!/bin/bash
# mocked tests for build_htp_retry_x86.sh (D130, Codex review of 91fe117): fake uname/docker/curl/ssh/scp on PATH, a
# local clone source with commit 836d57176 (REPO_URL), HOME in a temp dir. Checks: a normal run packs; long build logs
# do not end the script with SIGPIPE; missing toolchain provenance or SDK line stops before packing; an existing
# ~/llama.cpp-htp-retry with local edits and an earlier build are left untouched; the board copy never overwrites.
D=$(cd "$(dirname "$0")" && pwd); SRC=${SRC:-$HOME/v0/llama.cpp-hex}; SCRIPT=${SCRIPT:-$D/build_htp_retry_x86.sh}
PATCH=${PATCH:-$D/../upstream/htp-main-thread-retry.patch.txt}
git -C "$SRC" cat-file -e 836d57176dc699a726c55418e4f96b8ca628e1bf || { echo "need $SRC with commit 836d57176"; exit 9; }
fails=0
mkfakes() {  # mkfakes <dir>: mode files in $T: tc (ok|fail|wrongsdk), sdkline (yes|no)
  mkdir -p "$1"
  printf '#!/bin/bash\n[ "$1" = -m ] && echo x86_64 || /usr/bin/uname "$@"\n' > "$1/uname"
  cat > "$1/docker" <<'EOF'
#!/bin/bash
case $1 in
  info|pull) exit 0;;
  --version) echo "Docker version fake"; exit 0;;
  image) echo sha256:41b710ee5f99d21f0fb9d83a1f815ecffb7708315b4218a11cd0baeb5ecf4c14; exit 0;;
  run) args="$*"
    if [[ $args != *cmake* ]]; then  # toolchain provenance
      case $(cat $T/tc) in
        ok) printf 'HEXAGON_SDK_ROOT=/opt/hexagon/6.6.0.0\nHEXAGON_TOOLS_ROOT=/opt/hexagon/6.6.0.0/tools/HEXAGON_Tools/19.0.07\nQuIC LLVM Hexagon Clang version 19.0.07\n'; exit 0;;
        wrongsdk) printf 'HEXAGON_SDK_ROOT=/opt/hexagon/6.4.0.2\nHEXAGON_TOOLS_ROOT=/opt/hexagon/6.4.0.2/tools/HEXAGON_Tools/19.0.04\nclang version 19\n'; exit 0;;
        *) echo "bash: /Tools/bin/hexagon-clang: No such file or directory"; exit 1;;
      esac
    fi
    w=$(grep -oE -- '-v [^:]+:/workspace' <<< "$args" | sed -n '1{s/^-v //;s/:\/workspace$//;p}'); n=$(grep -oE 'build-(control|retry)' <<< "$args" | sed -n 1p); n=${n#build-}
    [ "$(cat $T/sdkline)" = yes ] && echo "-- hexagon: using /opt/hexagon/6.6.0.0 and /opt/hexagon/6.6.0.0/tools/HEXAGON_Tools/19.0.07 for building libggml-htp skels"
    seq 1 200000 | sed 's/^/-- htp-v75 Hexagon SDK object /'   # long, distinct matching output (SIGPIPE check)
    mkdir -p $w/pkg-$n/lib; { echo "dspqueue_peek failed: 0x%08x"; grep -oF 'in a row), retrying' $w/ggml/src/ggml-hexagon/htp/main.c; } > $w/pkg-$n/lib/libggml-htp-v75.so
    exit 0;;
esac; exit 1
EOF
  printf '#!/bin/bash\nwhile [ $# -gt 1 ]; do [ "$1" = -o ] && { cp "$PATCH" "$2"; exit 0; }; shift; done; exit 1\n' > "$1/curl"
  printf '#!/bin/bash\nh=$1; shift; cd $T/board && bash -c "$*"\n' > "$1/ssh"
  printf '#!/bin/bash\ncp "$1" $T/board/v0/\n' > "$1/scp"
  chmod +x "$1"/*; }
case1() { local name=$1 want=$2; shift 2  # want: ok | fail
  T=$(mktemp -d); export T PATCH; mkdir -p $T/home $T/board/v0; echo ok > $T/tc; echo yes > $T/sdkline
  local kv; for kv in "$@"; do echo "${kv#*=}" > $T/${kv%%=*}; done
  mkdir -p $T/home/llama.cpp-htp-retry; echo "owner edit" > $T/home/llama.cpp-htp-retry/keep.txt   # earlier work
  mkfakes $T/bin
  HOME=$T/home PATH=$T/bin:$PATH REPO_URL=$SRC bash "$SCRIPT" user@board > $T/out.txt 2>&1; local rc=$?
  local tars=$(ls $T/home/htp-retry-builds-*.tar.gz 2>/dev/null | wc -l) ok=1
  [ "$(cat $T/home/llama.cpp-htp-retry/keep.txt)" = "owner edit" ] || ok=0
  if [ $want = ok ]; then [ $rc = 0 ] && [ $tars = 1 ] && grep -qx DONE $T/out.txt && [ $(ls $T/board/v0 | wc -l) = 1 ] \
      && tar xzf $T/home/htp-retry-builds-*.tar.gz -O htp-retry-out/manifest.txt | grep -q 'libggml-htp-v75-retry.so sha256' || ok=0
  else [ $rc != 0 ] && [ $rc != 141 ] && [ $tars = 0 ] && ! grep -qx DONE $T/out.txt || ok=0; fi
  if [ $ok = 1 ]; then echo "ok   $name (rc $rc)"; else echo "FAIL $name (rc $rc, tarballs $tars)"; tail -5 $T/out.txt | sed 's/^/     /'; fails=$((fails+1)); fi
  if [ $name = normal ]; then  # a second run makes its own directory and tarball; the first is kept
    sleep 1; HOME=$T/home PATH=$T/bin:$PATH REPO_URL=$SRC bash "$SCRIPT" > $T/out2.txt 2>&1
    [ $? = 0 ] && [ $(ls -d $T/home/htp-retry-2* | wc -l) = 2 ] && [ $(ls $T/home/htp-retry-builds-*.tar.gz | wc -l) = 2 ] \
      && echo "ok   second-run-keeps-first" || { echo "FAIL second-run-keeps-first"; fails=$((fails+1)); }
    : > $T/board/v0/$(basename $(ls $T/home/htp-retry-builds-*.tar.gz | tail -1))   # same name already on the board
    f=$(ls $T/home/htp-retry-builds-*.tar.gz | tail -1); mv $f $T/keep.tgz; d=$(ls -d $T/home/htp-retry-2* | tail -1); rm -rf $d
    stamp=${f#*builds-}; stamp=${stamp%.tar.gz}
    # re-run with the clock pinned to that stamp so the board already holds the name
    printf '#!/bin/bash\n[ "$1" = +%%Y%%m%%d-%%H%%M%%S ] && echo %s || /usr/bin/date "$@"\n' "$stamp" > $T/bin/date; chmod +x $T/bin/date
    HOME=$T/home PATH=$T/bin:$PATH REPO_URL=$SRC bash "$SCRIPT" user@board > $T/out3.txt 2>&1
    [ $? != 0 ] && [ ! -s $T/board/v0/$(basename $f) ] && grep -q "already exists on the board" $T/out3.txt \
      && echo "ok   board-copy-never-overwrites" || { echo "FAIL board-copy-never-overwrites"; tail -3 $T/out3.txt; fails=$((fails+1)); }
  fi
  rm -rf $T; }
case1 normal ok
case1 toolchain-missing fail tc=fail
case1 toolchain-wrong-sdk fail tc=wrongsdk
case1 build-log-without-sdk-line fail sdkline=no
echo "failures: $fails"; exit $fails
