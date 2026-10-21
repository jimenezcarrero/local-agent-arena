#!/bin/bash
# fixture tests for the real b9_identity_check.sh (D180; as test_b4_identity_check.sh, plus the retry library):
# a tiny package with a manifest made by the real pkg_identity.py, a model file, a retry library and a .farf file under a temp dir; the
# clean case passes and each mutation (model, package file, extra package file, symlink target text, farf, missing model, retry library changed or missing) fails.
D=$(cd "$(dirname "$0")" && pwd); fails=0
case1() { local name=$1 want=$2 mut=$3
  T=$(mktemp -d); mkdir -p $T/pb/lib $T/pb/bin $T/farf
  echo lib > $T/pb/lib/libggml.so.0; ln -s libggml.so.0 $T/pb/lib/libggml.so; echo bin > $T/pb/bin/llama-server
  (cd $T/pb && sha256sum ./lib/libggml.so.0 ./bin/llama-server) > $T/rec.sha256
  python3 -I $D/pkg_identity.py make $T/rec.sha256 $T/pb > $T/man.txt || { echo "FAIL $name: manifest not made"; fails=$((fails+1)); rm -rf $T; return; }
  echo model > $T/m.gguf; echo 0x1f > $T/farf/llama-server.farf; mkdir -p $T/htpr; echo retry > $T/htpr/libggml-htp-v75.so
  local msha=$(sha256sum $T/m.gguf | cut -d' ' -f1) fsha=$(sha256sum $T/farf/llama-server.farf | cut -d' ' -f1) lsha=$(sha256sum $T/htpr/libggml-htp-v75.so | cut -d' ' -f1)
  eval "$mut"
  out=$(PKGID="python3 -I $D/pkg_identity.py" B9MAN=$T/man.txt PB=$T/pb B9M=$T/m.gguf B9M_SHA=$msha B9LIB=$T/htpr/libggml-htp-v75.so B9LIB_SHA=$lsha B9FARF=$T/farf/llama-server.farf \
        FARF_SHA=$fsha bash $D/b9_identity_check.sh 2>&1); rc=$?
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
case1 retry-library-changed 1 'echo control > $T/htpr/libggml-htp-v75.so'
case1 retry-library-missing 1 'rm $T/htpr/libggml-htp-v75.so'
echo "failures: $fails"; exit $fails
