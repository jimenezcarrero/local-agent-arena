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
       bash r1_models_x86.sh            (or BF16=<path to LFM2.5-24B-A2B-BF16.gguf> bash r1_models_x86.sh; relative
                                         paths and spaces are fine)
     The download goes to ~/r1-downloads/. If it is interrupted, rerun the same command: it resumes
     ~/r1-downloads/LFM2.5-24B-A2B-BF16.gguf.part; a complete file there is reused. Either is checked against the
     pinned size and sha256 before use; a download becomes the complete file only after both pass, and a failing
     file is named in the message (delete that file and rerun).
     Free disk needed under $HOME: 36 GiB for REF, M2 and the build, plus whatever is still to download (nothing with
     BF16= or a complete cached file; the rest of a partial one; 44.7 GiB for a new download).
     Checks: llama-quantize built for the host CPU at the same commit; BF16 from LiquidAI/LFM2.5-24B-A2B-GGUF at
     revision 0912d331, size 47,962,094,880 and Hub sha256 55103fda...; the table tool by sha256 (as reviewed in
     e4b35e8); lfm2moe with 40 blocks; every expert tensor of an NPU type; tables for M2 and REF (master, release,
     NPU-R' with the board's CPU repack types), 3 and 4 sessions at ctx 16,384, default and best explicit splits.
     The evidence also records the host reference runtime's identity (for T7 later): CMake's selected C/C++
     compilers with their versions, build type and flags, and the sha256 of llama-quantize, llama-perplexity and
     every shared library in the build output.
     Output: the models under ~/r1-k3-<stamp>/models (they stay on the host) and ~/r1-k3-evidence-<stamp>.tar.gz.

  3. Send back the two small records: ~/r1-k2-<stamp>/manifest.txt (plus pkg-unpatched-af0579c7.sha256,
     compile-flags.txt, toolchain.txt) and ~/r1-k3-evidence-<stamp>.tar.gz. They are committed here as R1's results;
     the session-count reading on M2 and the conservative pre-load admission calculation follow, then T7 (its text,
     token ids and settings pinned in K5 first).

Any FAILED line stops the script before packing; send the whole output back in that case. A rerun makes a new
directory and never touches an earlier one.

Tests (tests.txt): test_r1_host_scripts.sh 34/34, mocked (reviews of 702739a and 17130d9; df faked, the disk
guard not bypassed): K2 normal run and second run; failures for a non-x86
host, wrong image id, missing or wrong toolchain, a failed build, no SDK line, a non-aarch64 binary, a missing
libggml-htp-v75.so, i8mm or other compile flags. K3 with an existing and with a downloaded BF16, a relative BF16 path with a space, a download resumed
from an earlier .part, a complete earlier download reused; the host identity in the manifest; failures for a
corrupt earlier .part (never promoted), the disk admission for each source (an existing copy, a complete
or partial cached download, a new download: enough, and one byte short), a BF16
sha256 or size, the table tool's sha256, a non-lfm2moe header, an expert tensor of a non-NPU type (Q5_0),
a non-x86 host, a failed host build, a failed quantize. Each failure is checked for its own message.
