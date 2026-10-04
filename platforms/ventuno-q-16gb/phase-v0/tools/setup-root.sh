#!/bin/bash
# Ventuno Q V0 one-time root setup (RUNBOOK.md "One-time setup", after V0a).
# Run once:  sudo bash ~/local-agent-arena-v0/setup-root.sh
set -euxo pipefail
LOG=/home/arduino/local-agent-arena-v0/setup-root.log
exec > >(tee -a "$LOG") 2>&1
date -Is

# 1. Stay on 24.04 for the whole tier
sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades
grep ^Prompt /etc/update-manager/release-upgrades

# 2. Build/runtime packages (runbook list minus nodejs/npm: Node 22.23.3 and pi 0.80.10 are
#    installed user-level with mise, decision recorded in phase-v0/decisions.txt). Extra, needed by routes in the matrix:
#    python3-venv/pip (convert_hf_to_gguf), libvulkan-dev+glslc (Vulkan build),
#    OpenCL ICD + qcom-adreno-cl1 (GPU route), qemu-user-static+binfmt-support (the upstream
#    Hexagon toolchain container ghcr.io/snapdragon-toolchain/arm64-linux:v0.7 is amd64-only).
apt-get update
apt-get install -y build-essential cmake git python3 python3-pytest python3-venv python3-pip \
    gh jq clinfo vulkan-tools libvulkan-dev glslc \
    ocl-icd-opencl-dev opencl-headers qcom-adreno-cl1 \
    qemu-user-static binfmt-support

# 3. Durable kernel log (already persistent on this image) and lingering
mkdir -p /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
loginctl enable-linger arduino
loginctl show-user arduino -p Linger

# 4. Freeze the accelerator stack for the tier (unattended-upgrades stays on for everything else).
#    Reversible with: apt-mark unhold <pkg>
HOLD=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
  'linux-image-qcom' 'linux-qcom' 'linux-headers-qcom' 'linux-image-6.8.0-1084-qcom' 'linux-modules-6.8.0-1084-qcom' \
  'linux-firmware-dragonwing' 'mesa-vulkan-drivers' 'mesa-libgallium' 'libgl1-mesa-dri' 'libegl-mesa0' 'libglx-mesa0' \
  'qcom-adreno-cl1' 'qcom-fastrpc1' 'qcom-libdmabufheap' 2>/dev/null | awk '$1=="ii"{print $2}' || true)
apt-mark hold $HOLD
apt-mark showhold

# 5. Headless for every measured run (runbook "Before every session"), persistent across reboots.
#    Undo with: systemctl set-default graphical.target && systemctl isolate graphical.target
systemctl set-default multi-user.target
systemctl isolate multi-user.target
systemctl is-active gdm || true

# 6. Proof
su - arduino -c 'journalctl --system -k -n 1 -o short-iso' || true   # system kernel log readable by the batch user
dpkg-query -W -f='${Package} ${Version}\n' | sha256sum                # package-state fingerprint at setup end
clinfo -l || true
binfmt=$(ls /proc/sys/fs/binfmt_misc/ | grep -c x86_64 || true); echo "binfmt x86_64 entries: $binfmt"
date -Is
echo SETUP-ROOT-DONE
