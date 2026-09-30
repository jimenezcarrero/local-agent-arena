# Runbook: Arduino VENTUNO Q — Qualcomm Dragonwing IQ8 (QCS8275), 16GB

Instructions for an agent (or a person) continuing the campaign on this board.
The methodology is the one in [`../../suite/`](../../suite/README.md); this
file covers only what is specific to this machine and what to test here.

**What this tier is for:** the middle step between the Jetson's 8GB and the
laptop's 32GB. It asks what 16GB buys: the 9B configurations that took OOM
kills on the Jetson, higher-bit files, longer windows, and the Jetson questions
that needed more memory. It is **not** a controlled memory experiment: the CPU,
GPU, NPU, software stack and memory bandwidth all differ from the Jetson's, so
its results are a tier of their own and are never ranked against the Jetson or
the laptop (suite rule 7).

**The open risk is the backend, not the memory.** The Jetson had CUDA. This
board has three candidate accelerators, all young on Linux, and an agent
re-reads its whole transcript every turn, so prompt-processing speed decides
whether an arena finishes inside its time cap. V0 settles the backend before
any arena runs.

**Read [`suite/OPERATING.md`](../../suite/OPERATING.md) first.** Its lessons
from the Jetson campaign (3 runs per session cell, auditing failures, OOM
detection, sampling, unattended operation) all apply here.

## The machine

| | |
|---|---|
| SoC | Qualcomm Dragonwing IQ8, QCS8275: 8-core Kryo CPU, up to 2.36 GHz |
| GPU | Adreno 623. Mesa's Freedreno driver is reported as not yet optimised for it |
| NPU | Hexagon Tensor Processor, up to 40 dense TOPS. llama.cpp's Hexagon backend gives ~3.5GB of address space per NPU session, so a 9B needs several sessions |
| Memory | 16GB LPDDR5 (2×8GB), shared by CPU, GPU and NPU. **Record the bandwidth**: no published figure found |
| Storage | 64GB eMMC, plus an M.2 slot for NVMe (PCIe Gen 4). Models and `~/bench-runs` go on NVMe if one is fitted |
| MCU | STM32H5 (not used) |
| OS | **Ubuntu 24.04 LTS**, the image Canonical and Arduino ship for this board. Frozen for the whole tier (see below). Record the exact image, kernel, Mesa and Qualcomm package versions |

Record anything that differs from this table on your board in `phase-v0/files.txt`.

## Operating system: stay on 24.04 for the whole tier

The board offers an upgrade to Ubuntu 26.04. **Decline it.** 24.04 is the image
Canonical and Arduino ship and support for this board, and one OS for every run
keeps the tier's results comparable: an OS upgrade changes the kernel, Mesa and
the Qualcomm drivers at once. Qualcomm's user-space drivers come from Canonical's
`ppa:ubuntu-qcom-iot/qcom-ppa`, which publishes for 24.04 (and for 26.04). Stop
the prompt with `sudo sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades`.

Only if V0 finds that no accelerator works on 24.04 **because of driver
versions**, and that the 26.04 packages are newer, is an upgrade worth
considering. That is a decision for the person running the campaign, and the
whole of V0 is then re-run on 26.04 and recorded as a separate baseline.

## One-time setup (Ubuntu 24.04, arm64)

```bash
sudo apt update && sudo apt install -y build-essential cmake git python3 python3-pytest \
     nodejs npm pciutils clinfo ocl-icd-opencl-dev vulkan-tools libvulkan-dev glslc \
     mesa-vulkan-drivers gh jq software-properties-common
node --version              # Ubuntu 24.04 ships Node 18; if pi refuses to install or run, use NodeSource's 22.x
cat /etc/os-release; uname -r; nproc; free -m

# Qualcomm user space: Adreno OpenCL, FastRPC and Hexagon DSP firmware (Canonical's PPA;
# it may already be configured on the shipped image). Confirm package names with apt search.
grep -rq ubuntu-qcom-iot /etc/apt/sources.list.d/ || sudo add-apt-repository -y ppa:ubuntu-qcom-iot/qcom-ppa
sudo apt update
apt search qcom-adreno 2>/dev/null | grep -i adreno; apt search fastrpc 2>/dev/null | grep -i fastrpc
sudo apt install -y qcom-adreno1 fastrpc hexagon-dsp-binaries   # adjust to the names apt search shows
dpkg -l | grep -iE 'adreno|fastrpc|hexagon|qairt|mesa' > ~/qcom-packages.txt   # goes into phase-v0/files.txt
vulkaninfo --summary 2>&1 | grep -E 'deviceName|driverName|driverInfo'   # expect Turnip (Adreno) or nothing
clinfo -l 2>&1 | head       # an Adreno OpenCL platform, or none
ls -l /dev/fastrpc* 2>&1    # the Hexagon NPU's FastRPC devices, or none

# the repo, and commit identity: the public repo takes the GitHub noreply address, never a personal one
git clone https://github.com/jimenezcarrero/local-agent-arena ~/local-agent-arena
git -C ~/local-agent-arena config user.email 128645677+jimenezcarrero@users.noreply.github.com
git -C ~/local-agent-arena config user.name jimenezcarrero

# pi, pinned
sudo npm install -g @earendil-works/pi-coding-agent@0.80.10
mkdir -p ~/.pi/agent && cp ~/local-agent-arena/suite/models.json.example ~/.pi/agent/models.json

# MAKE THE KERNEL LOG DURABLE BEFORE THE FIRST RUN (the Jetson lost every OOM
# record to one reboot). As the account that will run the batch:
sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
journalctl --header | grep -m1 -i 'file path'   # must be under /var/log/journal
id -Gn | grep -qwE 'adm|systemd-journal' || sudo usermod -aG adm "$USER"   # then log out and in
journalctl --system -k -n 1 -o short-iso        # must print a kernel line
sudo loginctl enable-linger "$USER"
cat /proc/pressure/memory                       # PSI available? record yes/no
```

**Power:** the suite reads tegrastats (Jetson) or RAPL (Intel); this board has
neither, so runs record power as unmeasured. Don't estimate it. An inline USB-C
meter can be logged separately and reported as such.

Leave `BENCH_WORK` at its default (`~/bench-runs`, or a symlink to NVMe). The
suite refuses to run under any directory with an `AGENTS.md`/`CLAUDE.md` above it.

## Before every session

- Headless for every measured run (`sudo systemctl isolate multi-user.target`),
  as on the Jetson. Record `free -m` and the running services. Arduino's own
  services count against the 16GB, so note what is resident.
- One model at a time, nothing else on port 8080.
- `gh auth status` works in the session that will run the batch.
- Journal persistent and kernel history readable (see setup).
- Swap sampler running: `suite/tools/vmstat_sampler.sh >> ~/bench-runs/vmstat.log &`.
- Record the thermal state (`cat /sys/class/thermal/thermal_zone*/temp`) at the
  start and end. Preview units needed active cooling; say which cooling you used.

## Test plan

Each phase's rules are fixed before its first run, and a phase's thresholds are
frozen from the previous phase's measurements, never after seeing the results
they judge.

### V0: backend screen (no arenas)

**Reference model:** Ornith-1.0-9B IQ3_M, the same GGUF the Jetson ran (4.34
GiB). On the Jetson: pp512 281 tok/s, tg128 10.3 tok/s. Record its sha256.

Build llama.cpp at one pinned commit (record it), once per backend, each into
its own build directory:

| Build | How | Notes |
|---|---|---|
| `build-cpu` | `cmake -B build-cpu -DCMAKE_BUILD_TYPE=Release` | always works; the fallback |
| `build-vulkan` | `-DGGML_VULKAN=ON` | only if `vulkaninfo` shows the Adreno under Turnip |
| `build-opencl` | `-DGGML_OPENCL=ON` | only if `clinfo` shows an Adreno platform. llama.cpp's Adreno kernels expect Qualcomm's OpenCL driver |
| `build-hexagon` | per `docs/backend/snapdragon/README.md` in llama.cpp (Hexagon SDK; the Linux arm64 toolchain image) | only if `/dev/fastrpc*` exists. Canonical's `canonical/llama.cpp-builds` publishes the HTP DSP skeletons, which may save the SDK build. Time-box it to one day |

For each build that compiles and loads the model:

1. `llama-bench -m <ornith> -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 -b 512 -ub 128
   -p 512 -n 128 -d 0,8192,16384` (the Jetson's parity flags; add `-t 8` on
   CPU). If a flag isn't supported on a backend, record that and drop only that
   flag.
2. The tool-call probe, from `platforms/lunar-lake-32gb/` (after
   `mkdir -p ../ventuno-q-16gb/phase-v0`):
   `tools/probe_toolcalls.py probe <build> ../ventuno-q-16gb/phase-v0/probe.txt`
   against `llama-server` with the same flags, `--jinja`, at 32K. Ornith passes
   this on the Jetson, so anything short of 10/10 is a backend fault.
3. Peak RSS with the model loaded at 32K (`free -m` before and after).

**Selection rule:** among the builds with a 10/10 probe, the highest pp512 at
16K depth wins. Within 10% of it, the one with the higher tg128 at 16K wins. If
no accelerator passes, CPU is the backend. Write the table and the choice to
`phase-v0/README.md`, then freeze the V1–V2 speed thresholds there, before V1.

### V1: calibration against the Jetson

Ornith-1.0-9B IQ3_M on the V0 backend, the full ladder at the Jetson's parity
flags and windows (`65536 131072`), 3 runs per session cell, tag
`o10-parity`. The Jetson reference: arena 1–2 medians from its phase J
(140s / 426s at 65K); marathon 11/11 and every 32K crusher a full pass
(phase H); crusher at 131K 10m09s. Differences get audited, not explained in
advance: a slower backend is a result, a wrong tool call is a fault.

### V2: what 16GB buys

Candidates, frozen with the V0 thresholds: models that fit here and not on the
Jetson, or that took OOM kills there.

| Tag | Model | The question |
|---|---|---|
| `o15-iq4xs-65k` | Ornith-1.5-9B IQ4_XS @65K | killed in every Jetson marathon: clean here? |
| `o10-q6k` | Ornith-1.0-9B Q6_K @131K | the bits 8GB couldn't spare |
| `nh8-vp` | NeoHorse-1-4B Q8_0, vendor profile | a Jetson baseline at 8-bit |
| `k2h37-q8` | K2-Horizon-3.7B Q8_0 | does the Jetson's fastest marathon hold at 8-bit? (IFM fork if upstream lacks the arch) |
| `spark4b-bf16` | Spark-X2.5-4B BF16 | instability or quantization? |
| `e4b-98k-mtp` | gemma-E4B @98K with its MTP draft | failed to allocate on 8GB |
| `g4-12b-qat` | Gemma 4 12B QAT UD-Q4_K_XL (6.7GB) | a larger dense model within 16GB |
| `mimo9-q6-vp` | MiMo-V2.6-Distill-Qwen-9B Q6_K | only through the laptop runbook's two-step tool-call gate, applied here unchanged |

MoE files in the laptop's candidate list (14GB and up) leave no room for the OS
and KV cache here; they stay on the laptop.

## Recording results

Same layout as the laptop: `platforms/ventuno-q-16gb/phase-v<n>/` with
`results.txt`, `runs/<label>/`, `files.txt` (repo, file, sha256,
`check_sampling.sh` output, RSS), `notes.md` and `README.md`. Work on the
`ventuno-q` branch, touch only this folder, and open a PR to `main` per phase;
a person reviews it before merging. Never commit files matching `*draft*`.
