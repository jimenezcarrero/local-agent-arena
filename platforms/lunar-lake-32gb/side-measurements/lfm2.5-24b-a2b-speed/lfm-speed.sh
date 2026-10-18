#!/usr/bin/env bash
# lfm-speed.sh (revision 2): side measurement on the owner's Lunar Lake laptop, speed of LFM2.5-24B-A2B on CPU vs
# Vulkan iGPU with llama-bench at llama.cpp af0579c78 (T7's tree). NOT a campaign result, NOT part of the NPU plan.
# Settings: platforms/lunar-lake-32gb/RUNBOOK.md, S1 steps 2-3, `native` flags.
#
#   bash lfm-speed.sh                 a new run in ~/lfm-speed-<stamp>
#   W=<that dir> bash lfm-speed.sh    resume: finished benchmarks are skipped, everything else is checked again
#
# Builds happen inside T7's existing clone (~/r1-t7-20261017-093233/llama.cpp): llama-bench is added to its CPU build
# (build-host) and a Vulkan build dir is created next to it. T7's binaries are hashed before and checked after; the
# source is not modified. llama.cpp's own AGENTS.md/CLAUDE.md are about contributing to llama.cpp: this script only
# builds it, changes no file in it and contributes nothing; it runs from the work dir, outside any repository.
# Stops (exit 1) on any failed check or CPU failure. A Vulkan benchmark that fails (e.g. the model does not fit in
# the device heap) is recorded with its exit code and error and the run goes on; flags are never changed to force it.
set -uo pipefail

T="${T7DIR:-$HOME/r1-t7-20261017-093233}"
SRC="$T/llama.cpp"
M2="${M2:-$HOME/r1-k3-20261016-202009/models/LFM2.5-24B-A2B-M2-Q2_K-af0579c7.gguf}"
REF="${REF:-$HOME/r1-k3-20261016-202009/models/LFM2.5-24B-A2B-REF-Q8_0-af0579c7.gguf}"
Q4KM="${Q4KM:-$HOME/m4c/LFM2.5-24B-A2B-CAL-Q4_K_M.gguf}"
COMMIT="${COMMIT:-af0579c78a07a555d84830d01da7b61cfadbc7ef}"
INC="${INC:-/usr/include}"; MEMINFO="${MEMINFO:-/proc/meminfo}"
SZ_M2="${SZ_M2:-8809757984}"; SH_M2="${SH_M2:-43b42f90f64ed2c8ce46bf92a76adcc112dd69842d6c8c43f0fc44935bd914e7}"
SZ_REF="${SZ_REF:-25493732640}"; SH_REF="${SH_REF:-f09bf094a8a138c5b645598ca1abb6696a0fde26662d7af649b0713fdef330b6}"
SH_Q4="${SH_Q4:-d3334405b96228eb9908cdebb5c6194908f2da64282bda852afc3a3910c64e7d}"
INHIBIT=(${INHIBIT_CMD:-systemd-inhibit --what=idle:sleep:handle-lid-switch --why=bench})
BOARD="${BOARD:-arduino@192.168.1.39}"
W="${W:-$HOME/lfm-speed-$(date +%Y%m%d-%H%M%S)}"
E="$W/evidence"
mkdir -p "$E" || { echo "STOP: cannot create $E"; exit 1; }
cd "$W" || exit 1

log() { echo "$*" | tee -a "$E/status.txt"; }
die() { log "STOP: $*"; exit 1; }
gib_free() { df -BG --output=avail "$1" | tail -1 | tr -dc 0-9; }
kib_avail() { awk '/^MemAvailable:/ {print $2}' "$MEMINFO"; }

ov=$(env | grep -oE "^(T7DIR|M2|REF|Q4KM|INHIBIT_CMD|BOARD|COMMIT|INC|MEMINFO|SZ_M2|SH_M2|SZ_REF|SH_REF|SH_Q4)=" | tr -d = | tr "\n" " ")
log "=== lfm-speed revision 2, $(date -Iseconds), work dir $W; test overrides: ${ov:-no}"

# 0. host and session record (all of it, grouped; no hostname: uname -srmo)
{ echo "date: $(date -Iseconds)"; uname -srmo; lscpu | head -20; free -m
  echo "power profile: $(powerprofilesctl get 2>&1 || echo 'n/a')"
  echo "AC online: $(cat /sys/class/power_supply/A*/online 2>/dev/null | head -1 || echo 'n/a')"; } > "$E/host.txt" 2>&1

# 1. disk budget: the Vulkan build dir and logs need well under 3 GiB
f=$(gib_free "$HOME"); [ "${f:-0}" -ge 3 ] || die "free disk ${f}G < 3G"
log "disk OK: ${f}G free"

# 2. tools for the Vulkan build and the device record (installing them is the owner's step, not this script's)
miss=()
command -v vulkaninfo >/dev/null || miss+=(vulkan-tools)
command -v glslc >/dev/null || miss+=(shaderc)
[ -e "$INC/vulkan/vulkan.h" ] || miss+=(vulkan-headers)
[ -d "$INC/spirv" ] || miss+=(spirv-headers)
[ ${#miss[@]} -eq 0 ] || die "missing packages: ${miss[*]}. The owner installs them:  sudo pacman -S --needed ${miss[*]}"
log "Vulkan build tools OK"

# 3. models: size (M2, REF) and sha256 (all three)
{ for spec in "M2|$M2|$SZ_M2|$SH_M2" \
              "REF|$REF|$SZ_REF|$SH_REF" \
              "Q4KM|$Q4KM||$SH_Q4"; do
    IFS='|' read -r n p sz sha <<< "$spec"
    [ -f "$p" ] || { echo "MISSING $n $p"; continue; }
    s=$(stat -c %s "$p"); h=$(sha256sum "$p" | cut -d' ' -f1)
    ok=yes; [ -n "$sz" ] && [ "$s" != "$sz" ] && ok=no; [ "$h" != "$sha" ] && ok=no
    echo "$n $p bytes $s sha256 $h match $ok"
  done; } > "$E/models.txt"
cat "$E/models.txt" >> "$E/status.txt"
grep -qE 'MISSING| match no$' "$E/models.txt" && die "model check failed (see models.txt)"
log "models OK"

# 4. T7's tree: commit, clean, binaries hashed before building anything
[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" = "$COMMIT" ] || die "T7 tree not at $COMMIT"
[ -z "$(git -C "$SRC" status --porcelain 2>/dev/null)" ] || die "T7 tree not clean"
if [ ! -s "$E/t7-bins-before.sha256" ]; then
  (cd "$SRC/build-host/bin" && sha256sum llama-perplexity llama-server lib*.so*) > "$E/t7-bins-before.sha256" \
    || die "cannot hash T7 binaries"
fi

# 5. builds: CPU = T7's build-host (Release, GGML_NATIVE=ON) + llama-bench; Vulkan = new build-vulkan (Release, GGML_VULKAN=ON)
cmake --build "$SRC/build-host" -j8 --target llama-bench > "$E/build-cpu.log" 2>&1 || die "CPU build failed (build-cpu.log)"
(cd "$SRC/build-host/bin" && sha256sum -c "$E/t7-bins-before.sha256") > "$E/t7-bins-after.check" 2>&1 \
  || die "T7 binaries changed (t7-bins-after.check)"
{ cmake -S "$SRC" -B "$SRC/build-vulkan" -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON \
  && cmake --build "$SRC/build-vulkan" -j8 --target llama-bench; } > "$E/build-vulkan.log" 2>&1 \
  || die "Vulkan build failed (build-vulkan.log)"
[ -z "$(git -C "$SRC" status --porcelain 2>/dev/null)" ] || die "T7 tree not clean after the builds"
(cd "$SRC" && sha256sum build-host/bin/llama-bench build-host/bin/lib*.so* build-vulkan/bin/llama-bench build-vulkan/bin/lib*.so*) \
  > "$E/binaries.sha256" 2>&1 || die "cannot hash the benchmark binaries"
log "builds OK; T7 binaries unchanged"

# 6. Vulkan device and heaps (the device-local heap caps weights + KV)
{ lspci -k | grep -A3 -iE 'vga|display' || echo "(no vga/display line from lspci)"; echo; } > "$E/vulkan.txt" 2>&1
# only named fields are kept: vulkaninfo also prints deviceUUID/driverUUID, which are device identifiers
vs=$(vulkaninfo --summary 2>&1) || die "vulkaninfo --summary failed"
printf "%s\n" "$vs" | grep -E "^\s*(apiVersion|driverVersion|vendorID|deviceID|deviceType|deviceName|driverID|driverName|driverInfo|conformanceVersion)\s*=" \
  | grep -viE "uuid|luid|serial" >> "$E/vulkan.txt" || die "vulkaninfo --summary: no device fields found"
{ echo; vulkaninfo 2>/dev/null | grep -A4 memoryHeaps || echo "(no memoryHeaps lines)"; } >> "$E/vulkan.txt"
log "Vulkan device recorded"

# 7. benchmarks: per model (M2, Q4KM, REF), CPU then Vulkan; cold 32K prefill, then 512/128 at depth 0, 16K, 32K
common=(-ngl 99 -fa 1 -ctk q8_0 -ctv q8_0 -b 2048 -ub 512 -t 4 -r 3 -o md)
declare -A MP=([M2]="$M2" [Q4KM]="$Q4KM" [REF]="$REF")
declare -A NEED=([M2]=18 [Q4KM]=18 [REF]=26)
for name in M2 Q4KM REF; do
  for b in cpu vulkan; do
    bin="$SRC/build-host/bin/llama-bench"; [ "$b" = vulkan ] && bin="$SRC/build-vulkan/bin/llama-bench"
    for t in cold32k depth; do
      out="$E/bench-$name-$b-$t.txt"
      [ -e "$out.done" ] && { log "skip $name $b $t (done)"; continue; }
      [ -e "$out.failed" ] && { log "skip $name $b $t (recorded as failed)"; continue; }
      a=$(kib_avail); need=$(( NEED[$name] * 1048576 ))
      echo "$(date -Iseconds) before $name $b $t MemAvailable ${a} kB (need ${need})" >> "$E/memory.txt"
      [ "$a" -ge "$need" ] || die "MemAvailable ${a} kB < ${NEED[$name]} GiB before $name $b $t: close apps by hand, then resume with W=$W"
      if [ "$t" = cold32k ]; then args=(-p 32768 -n 0 -d 0); else args=(-p 512 -n 128 -d 0,16384,32768); fi
      log "run $name $b $t ($(date -Iseconds))"
      "${INHIBIT[@]}" "$bin" -m "${MP[$name]}" "${common[@]}" "${args[@]}" > "$out" 2>&1; rc=$?
      { echo "$(date -Iseconds) after $name $b $t exit $rc"; free -m; } >> "$E/memory.txt"
      if [ "$rc" -eq 0 ]; then touch "$out.done"; log "done $name $b $t"
      elif [ "$b" = vulkan ]; then
        echo "$rc" > "$out.failed"; log "VULKAN FAILED $name $t exit $rc (recorded; not forced). Last lines:"
        tail -15 "$out" | tee -a "$E/status.txt"
      else die "CPU benchmark failed: $name $t exit $rc (see $out)"; fi
    done
  done
done

# 8. package exactly this run's evidence and send it
log "=== finished $(date -Iseconds)"
A="$HOME/lfm-speed-evidence-$(basename "$W").tar.gz"
tar -czf "$A" -C "$W" evidence || die "tar failed"
sha256sum "$A" | tee -a "$A.sha256"
scp -o HostKeyAlias=ventunoq.local "$A" "$BOARD:r1-incoming/" \
  && echo "copied to the board" \
  || echo "copy failed; send it by hand:  scp -o HostKeyAlias=ventunoq.local $A $BOARD:r1-incoming/"
exit 0
