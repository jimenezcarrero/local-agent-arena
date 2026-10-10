#!/bin/bash
# shim_manifest.sh <shim dir> [--build] (D125, Codex review of 892d7b9 finding 4): build record of one dspq_probe shim
# variant (~/v0/dspq_probe, ~/v0/dspq_kick, ...). With --build it first compiles <dir>/dspq_probe.c with the one build
# command below. It prints: the source hash and the repository commits whose tools/dspq_probe.c has that hash, the build
# command, a rebuild of the same source in a temporary directory compared byte for byte with the deployed binary (shows
# that the command reproduces it), the binary's hash, SONAME and NEEDED, the real FastRPC library (path, hash, package
# version) and which object provides each of the 19 functions ggml-hexagon resolves (shim_symcheck.c).
set -uo pipefail
D=$(realpath "$1"); REPO=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel); REAL=/lib/aarch64-linux-gnu/libcdsprpc.so.1
build() { gcc -O2 -Wall -Wextra -shared -fPIC -Wl,-soname,libcdsprpc.so -o "$2" "$1" -ldl -lpthread -Wl,--no-as-needed $REAL; }
CMD='gcc -O2 -Wall -Wextra -shared -fPIC -Wl,-soname,libcdsprpc.so -o <dir>/libcdsprpc.so <dir>/dspq_probe.c -ldl -lpthread -Wl,--no-as-needed /lib/aarch64-linux-gnu/libcdsprpc.so.1'
[ "${2:-}" = --build ] && { build "$D/dspq_probe.c" "$D/libcdsprpc.so" || exit 1; }
src=$(sha256sum < "$D/dspq_probe.c" | cut -d' ' -f1)
echo "# dspq_probe shim build record, $(date -Is)"
echo "dir: ${D/#$HOME/~}"
echo "source: dspq_probe.c sha256 $src"
echo -n "source matches tools/dspq_probe.c at commits:"
for c in $(git -C "$REPO" log --format=%h -- platforms/ventuno-q-16gb/phase-v0/tools/dspq_probe.c); do
  [ "$(git -C "$REPO" show $c:platforms/ventuno-q-16gb/phase-v0/tools/dspq_probe.c | sha256sum | cut -d' ' -f1)" = "$src" ] && echo -n " $c"; done
[ "$(sha256sum < "$REPO/platforms/ventuno-q-16gb/phase-v0/tools/dspq_probe.c" | cut -d' ' -f1)" = "$src" ] && echo -n " working-tree"; echo
echo "build command: $CMD"
echo "compiler: $(gcc --version | head -1); linker: $(ld --version | head -1)"
T=$(mktemp -d); build "$D/dspq_probe.c" "$T/libcdsprpc.so" 2> "$T/err"
if cmp -s "$T/libcdsprpc.so" "$D/libcdsprpc.so"; then echo "rebuild from this source: byte-identical to the deployed binary"
else echo "rebuild from this source: DIFFERS from the deployed binary"; fi
echo "binary: libcdsprpc.so sha256 $(sha256sum < "$D/libcdsprpc.so" | cut -d' ' -f1)"
readelf -d "$D/libcdsprpc.so" | grep -E 'SONAME|NEEDED' | sed 's/^ */  /'
echo "real library: $REAL -> $(readlink -f $REAL) sha256 $(sha256sum < $REAL | cut -d' ' -f1), package qcom-fastrpc1 $(dpkg-query -W -f='${Version}' qcom-fastrpc1)"
gcc -O2 -Wall -o "$T/symcheck" "$(dirname "$0")/shim_symcheck.c" -ldl || exit 1
echo "symbol resolution (dlopen(\"libcdsprpc.so\") with LD_LIBRARY_PATH=<dir>:<package lib>, as the server runs it):"
LD_LIBRARY_PATH="$D:$HOME/v0/hexpkg/pkg-linux/lib" "$T/symcheck" | sed "s|$HOME|~|; s/^/  /"; rc=${PIPESTATUS[0]}
rm -rf "$T"; exit $rc
