Side measurement on this laptop: speed of LFM2.5-24B-A2B (M2, Q4_K_M, REF) on CPU vs Vulkan iGPU, revision 3.
NOT a campaign result, NOT part of the NPU plan. The steps are in the script lfm-speed.sh (fetched with this file and
checked by sha256); follow these instructions exactly, do not edit the script, and report instead of improvising.

1. Packages (the owner's step; the agent does not install anything). The script names any missing package and stops.
   The runbook's set for the Vulkan build and the device record:
     sudo pacman -S --needed vulkan-tools vulkan-headers spirv-headers shaderc vulkan-intel vulkan-icd-loader
2. Session, before step 3: AC power connected; set the profile with  powerprofilesctl set performance  (if the command
   exists) and check it with  powerprofilesctl get  (the script only records it).
   Memory: the script requires MemAvailable >= 18 GiB before M2 and Q4_K_M runs, >= 26 GiB before REF runs. If it stops
   on memory, close apps by hand (not by name pattern) and resume (step 4). Disk: it requires >= 3 GiB free.
3. Run, outside any repository (the script works in ~/lfm-speed-<stamp> and builds inside T7's existing llama.cpp tree
   without changing its source or T7's binaries; llama.cpp's AGENTS.md/CLAUDE.md concern contributions to llama.cpp,
   and this run contributes nothing):
     bash -c 'cd ~/Work/prompts && bash lfm-speed.sh 2>&1 | tee ~/lfm-speed-console.log; rc=${PIPESTATUS[0]}; echo "exit=$rc"; exit $rc'
   (bash -c so the exit code is right from zsh too)
   Expect several hours (REF on the CPU is the slowest). Do not interrupt; do not open apps while it runs.
4. If it stops: report the STOP line. After fixing the cause (e.g. memory), resume in the same work dir:
     bash -c 'cd ~/Work/prompts && W=<the work dir printed on the first line> bash lfm-speed.sh 2>&1 | tee -a ~/lfm-speed-console.log; rc=${PIPESTATUS[0]}; echo "exit=$rc"; exit $rc'
   Evidence holds no device identifiers: vulkaninfo is filtered to named fields (no UUIDs) and host.txt has no hostname.
5. At the end it archives exactly this run's evidence (~/lfm-speed-evidence-<stamp>.tar.gz), prints its sha256 and copies
   it with scp -o HostKeyAlias=ventunoq.local to arduino@192.168.1.39:r1-incoming/. Report: exit code, sha256, any
   "VULKAN FAILED" lines (a model that does not fit is recorded, not forced), and whether the copy succeeded.
