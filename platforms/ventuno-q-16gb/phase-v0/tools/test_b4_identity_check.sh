#!/bin/bash
# fixture tests for the real b4_identity_check.sh (D178, review of 4d278e0: the integration tests mock it wholesale):
# a tiny package with a manifest made by the real pkg_identity.py, a model file and a .farf file under a temp dir; the
# clean case passes and each mutation (model, package file, extra package file, symlink target text, farf, missing model) fails.
D=$(cd "$(dirname "$0")" && pwd); fails=0
case1() { local name=$1 want=$2 mut=$3
  T=$(mktemp -d); mkdir -p $T/pb/lib $T/pb/bin $T/farf
  echo lib > $T/pb/lib/libggml.so.0; ln -s libggml.so.0 $T/pb/lib/libggml.so; echo bin > $T/pb/bin/llama-server
  (cd $T/pb && sha256sum ./lib/libggml.so.0 ./bin/llama-server) > $T/rec.sha256
  python3 -I $D/pkg_identity.py make $T/rec.sha256 $T/pb > $T/man.txt || { echo "FAIL $name: manifest not made"; fails=$((fails+1)); rm -rf $T; return; }
  echo model > $T/m.gguf; echo 0x1f > $T/farf/llama-server.farf
  local msha=$(sha256sum $T/m.gguf | cut -d' ' -f1) fsha=$(sha256sum $T/farf/llama-server.farf | cut -d' ' -f1)
  eval "$mut"
  out=$(PKGID="python3 -I $D/pkg_identity.py" B4MAN=$T/man.txt PB=$T/pb B4M=$T/m.gguf B4M_SHA=$msha B4FARF=$T/farf/llama-server.farf \
        FARF_SHA=$fsha bash $D/b4_identity_check.sh 2>&1); rc=$?
  if [ $rc = $want ] && { { [ $want = 0 ] && [[ "$out" == OK* ]]; } || { [ $want = 1 ] && [[ "$out" == FAILED* ]]; }; }; then echo "ok   $name (rc $rc)"
  else echo "FAIL $name (rc $rc want $want): $out"; fails=$((fails+1)); fi
  rm -rf $T; }
case1 clean 0 :
case1 model-changed 1 'echo other > $T/m.gguf'
case1 model-missing 1 'rm $T/m.gguf'
case1 package-file-changed 1 'echo patched > $T/pb/lib/libggml.so.0'
case1 package-extra-file 1 'echo x > $T/pb/lib/libextra.so'
case1 package-link-retargeted 1 'ln -sfn ./libggml.so.0 $T/pb/lib/libggml.so'
case1 farf-changed 1 'echo 0x00 > $T/farf/llama-server.farf'
echo "failures: $fails"; exit $fails
