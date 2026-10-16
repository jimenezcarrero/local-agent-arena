K2 result (NPU dev plan K2, stage R1): the unpatched control package of ggml-org master af0579c78, built by the owner
on the x86_64 laptop on 2026-10-16 (10:23-10:30) with r1_build_master_x86.sh at the reviewed commit ceb2688 (sha256
1391258a..., checked before the run). Result: DONE, exit 0. No NPU, nothing staged on the board.

Owner's exceptions to the R1 run rules, both recorded before use:
  - Docker on the laptop needs sudo: the owner ran K2 personally with a run-local shim, docker = "sudo -n
    <absolute docker path>" (as for D131), the credential kept alive by a background "sudo -n -v" loop ended by a trap.
    The script itself is unchanged; the container ran as the owner's uid (-u). The agent did not use sudo.
  - This records tarball (text only: the files below; no binary) was copied to ~/r1-incoming/ on the board for
    committing. sha256 2aad911b61fcf3288ec56c782f1725bb26d34db9b07e30012818b78b7435e2b3 (on the board after the copy, and
    the same on the laptop's source file: the copy is exact). The package tarball and
    the models stay on the laptop; staging for R2 needs its own approval.

Files: manifest.txt, pkg-unpatched-af0579c7.sha256 (132 files), compile-flags.txt, toolchain.txt, k2-output-tail.txt
(the last 40 lines of the run's output), package-tarball.sha256.

Checks (on the board, 2026-10-16):
  - source af0579c78a07a555d84830d01da7b61cfadbc7ef, fresh clone, clean, unpatched; image
    ghcr.io/snapdragon-toolchain/arm64-linux:v0.7 sha256:41b710ee... (the campaign's); SDK 6.6.0.0, tools 19.0.07,
    QuIC LLVM Hexagon Clang 19.0.07; the SDK line in the build log.
  - compile flags -march=armv8.2a+fp16+dotprod, no i8mm: the CPU repack types assumed by the R1 tables for NPU-R'.
  - the hash list's sha256 equals the manifest's (7c623383...); 132 regular files; the package tarball's sha256
    d0ca1bb5... is the same in the manifest's output and in package-tarball.sha256.
  - against the campaign's release package (836d57176, ~/v0/hexpkg/pkg-linux): libggml-htp-v75.so 444b28eb... vs
    1fd898cc... (the DSP code differs, as expected); libllama-server-impl.so fff19ef5... vs 96beb832...;
    libllama.so.0.6.0 a5d9db20... vs .0.5.0 5e28c161...; libggml-hexagon.so.0.26.0 82dea5a7... vs .0.25.3 53130fb4....
Findings:
  - bin/llama-server is byte-identical to the release's (815b22bb..., 70,624 bytes): it is a small launcher that
    loads lib/libllama-server-impl.so, so its hash does not identify the server's code. The campaign's identity
    checks pin llama-server, the DSP library, the .farf and the model; the host libraries (libllama-server-impl.so,
    libllama.so, libggml-*.so) are not in them. Proposed for the campaign (owner's decision, a reviewed change on the
    ventuno-q branch, not made): add those hashes to the launch checks before A32-5. Here the full 132-file list
    identifies the package.
    Since made (2026-10-16): D176 on the ventuno-q branch (PR #62), the whole release package checked at every
    launch from A32-5 on.
  - Defect in r1_build_master_x86.sh's manifest (display only): "lib/libggml-hexagon.so ... bytes 20" is the
    symlink's length (stat without -L); its sha256 is the real library's (sha256sum follows the link; it equals
    libggml-hexagon.so.0.26.0 in the hash list). To fix with stat -L in the next revision; the records stand.
Next: K3 (M2, REF and their tables) on the laptop; then M2's session count and the conservative pre-load admission
calculation; T7 after K5 pins its text and settings.
