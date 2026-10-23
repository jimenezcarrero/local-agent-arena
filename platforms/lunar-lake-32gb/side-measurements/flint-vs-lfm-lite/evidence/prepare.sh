#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
work=${1:?Pass the exact run directory}
repository="$HOME/Work/local-agent-arena"
commit=a37cc46104eb50900d5ab4a9ba02a0abdac039db
source="$work/llama.cpp"
model="$work/models/RecursiveSI_flint-Q3_K_M.gguf"
mkdir -p "$work/evidence" "$work/models"
exec 9> "$work/prepare.lock"
flock -n 9 || { echo 'STOP: preparation already running'; exit 1; }
exec > >(tee -a "$work/prepare-console.log") 2>&1
trap 'result=$?; printf "prepare exit=%s at %s\n" "$result" "$(date -Iseconds)"; exit "$result"' EXIT
date -Iseconds
python3 - <<'PY'
import os
memory=next(int(line.split()[1])*1024 for line in open('/proc/meminfo') if line.startswith('MemAvailable:'))
stats=os.statvfs(os.path.expanduser('~')); disk=stats.f_bavail*stats.f_frsize
for label,amount in [('RAM',memory),('disk',disk)]:
    print(f'{label}: {amount/1024**3:.3f} GiB')
    if amount<26*1024**3: raise SystemExit('STOP: '+label+' below approved 26 GiB guard')
PY
for name in git cmake c++ curl python3 tar vulkaninfo glslc flock systemd-inhibit; do command -v "$name" >/dev/null || { echo "STOP: missing $name; owner installs packages"; exit 1; }; done
for name in llama-server llama-bench ninja cmake; do
    if pgrep -x "$name" >/dev/null; then echo "STOP: $name already active"; exit 1; fi
done
test "$(powerprofilesctl get)" = performance || { echo 'STOP: performance profile required'; exit 1; }
test "$(cat /sys/class/power_supply/A*/online | head -1)" = 1 || { echo 'STOP: AC power required'; exit 1; }
cp "$root/prepare.sh" "$work/evidence/prepare.sh"
cp "$HOME/Work/prompts/flint-lite-plan-20261022.md" "$work/evidence/plan.md"
cp "$repository/suite/tools/probe_toolcalls.py" "$work/evidence/probe_toolcalls.py"
cp "$repository/suite/check_sampling.sh" "$work/evidence/check_sampling.sh"
git -C "$repository" rev-parse HEAD > "$work/evidence/suite-commit.txt"
sha256sum "$work/evidence/probe_toolcalls.py" "$work/evidence/check_sampling.sh" > "$work/evidence/suite-tools.sha256"
{
 date -Iseconds
 uname -srm
 cmake --version | head -1
 c++ --version | head -1
 powerprofilesctl get
} > "$work/evidence/environment.txt"
vulkaninfo --summary 2>/dev/null | awk '/deviceName|driverName|driverInfo|apiVersion/ {print}' > "$work/evidence/vulkan-summary.txt"
vulkaninfo 2>/dev/null | awk '/memoryHeapCount|memoryHeaps\[|heapBudget|heapUsage/ {print}' > "$work/evidence/vulkan-budget.txt"
printf '%s  %s\n' d3334405b96228eb9908cdebb5c6194908f2da64282bda852afc3a3910c64e7d "$HOME/m4c/LFM2.5-24B-A2B-CAL-Q4_K_M.gguf" | sha256sum -c -
if [ ! -e "$source" ]; then git clone --no-checkout https://github.com/ggml-org/llama.cpp.git "$source"; fi
git -C "$source" checkout --detach "$commit"
test "$(git -C "$source" rev-parse HEAD)" = "$commit"
git -C "$source" merge-base --is-ancestor 9febe63d5a379f8568bae7116a5b2ba844a4a4a6 "$commit"
test -z "$(git -C "$source" status --porcelain)"
printf '%s\n' "$commit" > "$work/evidence/llama-commit.txt"
printf '%s\n' 'cmake -S llama.cpp -B llama.cpp/build-vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release' 'cmake --build llama.cpp/build-vulkan -j8 --target llama-server llama-cli llama-bench' > "$work/evidence/build-commands.txt"
cmake -S "$source" -B "$source/build-vulkan" -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release 2>&1 | tee "$work/evidence/configure.log"
cmake --build "$source/build-vulkan" -j8 --target llama-server llama-cli llama-bench 2>&1 | tee "$work/evidence/build.log"
test -z "$(git -C "$source" status --porcelain --untracked-files=no)"
cp "$source/build-vulkan/CMakeCache.txt" "$work/evidence/CMakeCache.txt"
sha256sum "$source/build-vulkan/bin/llama-server" "$source/build-vulkan/bin/llama-cli" "$source/build-vulkan/bin/llama-bench" > "$work/evidence/binaries.sha256"
if [ ! -f "$model" ]; then
 python3 - "$model.part" <<'PY'
import os,sys
stats=os.statvfs(os.path.expanduser('~')); available=stats.f_bavail*stats.f_frsize
partial=os.path.getsize(sys.argv[1]) if os.path.exists(sys.argv[1]) else 0
need=max(0,19529151712-partial)+5*1024**3
if available<need: raise SystemExit('STOP: insufficient disk for remaining download plus 5 GiB reserve; ask owner what to delete')
PY
 curl -fL -C - --connect-timeout 30 -o "$model.part" https://huggingface.co/bartowski/RecursiveSI_flint-GGUF/resolve/a04b26fbb0f68a0ab21ff6dc062f9119700267c7/RecursiveSI_flint-Q3_K_M.gguf
 test "$(stat -c %s "$model.part")" = 19529151712
 printf '%s  %s\n' 1d6d5800dbed15e60c6ca8b3af9f131a5570bae3f1b85a552632930dc033a7ea "$model.part" | sha256sum -c -
 mv -- "$model.part" "$model"
fi
printf '%s  %s\n' 1d6d5800dbed15e60c6ca8b3af9f131a5570bae3f1b85a552632930dc033a7ea "$model" | sha256sum -c -
printf '%s\n' 'Flint: bartowski/RecursiveSI_flint-GGUF at a04b26fbb0f68a0ab21ff6dc062f9119700267c7; RecursiveSI_flint-Q3_K_M.gguf; 19529151712 bytes; sha256 1d6d5800dbed15e60c6ca8b3af9f131a5570bae3f1b85a552632930dc033a7ea; publisher declares quantized released RecursiveSI/flint; imatrix/custom per-tensor layout.' 'LFM: existing CAL-Q4_K_M; 14526258464 bytes; sha256 d3334405b96228eb9908cdebb5c6194908f2da64282bda852afc3a3910c64e7d.' > "$work/evidence/models.txt"
date -Iseconds > "$work/evidence/prepared.txt"
echo 'PREPARATION DONE; measure.py performs invocation guards before any benchmark/server.'
