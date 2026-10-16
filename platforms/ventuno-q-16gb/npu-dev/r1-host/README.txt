R1 on the owner's x86_64 host (NPU dev plan, section 6 R1; K2 and K3 in section 3). Declared 2026-10-16 for review.
Nothing here touches the board: no copy, no install, no NPU. Staging and the load probe belong to R2 (its own
reviewed manifest, wrapper, staging reserve and the owner's approval).

Needs: Linux x86_64, Docker (K2), git, cmake, a C++ compiler, curl, python3, about 90 GiB free under $HOME (K3; about
40 GiB with an existing BF16 copy). Fetch each script from the reviewed commit (not the moving branch), run it as a
whole file:

  1. K2, unpatched control package of master af0579c78 (about 20-40 min):
       curl -fsSL https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/<commit>/platforms/ventuno-q-16gb/npu-dev/tools/r1_build_master_x86.sh -o r1_build_master_x86.sh
       bash r1_build_master_x86.sh
     Checks: fresh clone at the pinned commit, clean; toolchain image by id with SDK 6.6.0.0 / tools 19.0.07; the
     documented preset and commands; the SDK line in the build log; llama-server an aarch64 ELF; libggml-htp-v75.so
     and the tools present; compile flags -march=armv8.2a+fp16+dotprod (no i8mm: they decide the CPU repack types
     that the R1 table assumes for NPU-R'). Output ~/pkg-unpatched-af0579c7-<stamp>.tar.gz and ~/r1-k2-<stamp>/.

  2. K3, M2 (Q2_K, default mix, no imatrix) and REF (Q8_0) from Liquid's BF16 (about 1-2 h, most of it the 48 GB
     download and hashing):
       curl -fsSL https://raw.githubusercontent.com/jimenezcarrero/local-agent-arena/<commit>/platforms/ventuno-q-16gb/npu-dev/tools/r1_models_x86.sh -o r1_models_x86.sh
       bash r1_models_x86.sh            (or BF16=<path to LFM2.5-24B-A2B-BF16.gguf> bash r1_models_x86.sh)
     Checks: llama-quantize built for the host CPU at the same commit; BF16 from LiquidAI/LFM2.5-24B-A2B-GGUF at
     revision 0912d331, size 47,962,094,880 and Hub sha256 55103fda...; the table tool by sha256 (as reviewed in
     e4b35e8); lfm2moe with 40 blocks; every expert tensor of an NPU type; tables for M2 and REF (master, release,
     NPU-R' with the board's CPU repack types), 3 and 4 sessions at ctx 16,384, default and best explicit splits.
     Output: the models under ~/r1-k3-<stamp>/models (they stay on the host) and ~/r1-k3-evidence-<stamp>.tar.gz.

  3. Send back the two small records: ~/r1-k2-<stamp>/manifest.txt (plus pkg-unpatched-af0579c7.sha256,
     compile-flags.txt, toolchain.txt) and ~/r1-k3-evidence-<stamp>.tar.gz. They are committed here as R1's results;
     the session-count reading on M2 and the conservative pre-load admission calculation follow, then T7 (its text,
     token ids and settings pinned in K5 first).

Any FAILED line stops the script before packing; send the whole output back in that case. A rerun makes a new
directory and never touches an earlier one.

Tests (tests.txt): test_r1_host_scripts.sh 23/23, mocked: K2 normal run and second run; failures for a non-x86
host, wrong image id, missing or wrong toolchain, a failed build, no SDK line, a non-aarch64 binary, a missing
libggml-htp-v75.so, i8mm or other compile flags. K3 with an existing and with a downloaded BF16; failures for BF16
sha256 or size, the table tool's sha256, a non-lfm2moe header, an expert tensor of a non-NPU type (Q5_0), low disk,
a non-x86 host, a failed host build, a failed quantize. Each failure is checked for its own message.
