# Qwen3.8-27B headless test — run without Claude

All three GGUFs are already downloaded. The test runs itself at boot; you only
reboot twice and read the result.

## 1. Go headless and start the test

    sudo systemctl enable qwen38-test          # run the test on next boot
    sudo systemctl set-default multi-user.target
    sudo reboot

The board comes back with no desktop. Log in at the text console
(or SSH in). **Don't start Claude** — it costs ~470 MB that the test needs.

## 2. Watch it

    q38status                 # one-shot summary
    watch -n 15 q38status     # live view, Ctrl-C to leave (does not stop the test)

You'll see:

    ● RUNNING   step 2 of 3  —  IQ1_M
      phase:    loading ngl=56   (this step: 1m 20s)
      elapsed:  6m 44s   mode: partial
      errors:   none

- `step X of 3`   = which quant (IQ2_XXS -> IQ1_M -> IQ1_S, biggest first)
- `phase`         = loading ngl=N / measuring ngl=N / waiting-for-download
- `errors: none`  = nothing went wrong. A line saying `FAIL allocating ... MiB`
                    is normal data (that config didn't fit), not an error.
- Done when the first line reads `✓ COMPLETE  all 3 steps finished`.
- If the run dies, the first line says `✗ STOPPED UNEXPECTEDLY` instead.

Expected runtime: 20-60 min. A dense 27B on CPU+GPU split is slow; a single
100-token reply can take several minutes. That is not a hang — `phase` will say
`measuring` and the per-step timer keeps counting.

## 3. Restore your desktop

    sudo systemctl disable qwen38-test         # so it doesn't re-run every boot
    sudo systemctl set-default graphical.target
    sudo reboot

## 4. Results

    cat ~/Repositories/round5-newmodels/qwen38-results.txt

Then start Claude again (`claude -c` to resume this conversation) and I'll
interpret the numbers.

## If something looks wrong

- Nothing happening / no status file:
      systemctl status qwen38-test --no-pager
      journalctl -u qwen38-test -n 50
- Stop the test early:
      sudo systemctl stop qwen38-test
      pkill -f "llama serve"
- Re-run it by hand instead of at boot:
      cd ~/Repositories/round5-newmodels
      ./run_qwen38.sh partial 2048 off f16

## What it's testing and why

Flash attention is unsupported for this model on this GPU in the installed
build, so the test runs `-fa off`. That inflates the KV/compute buffers, which
is why it needs headless (~6.9 GB free vs ~5.2 GB with the desktop). For each
quant it steps `-ngl` down (99, 56, 48, 40, 32, 24, 16, 8, 0) until the model
loads, then measures prompt and generation speed - so the result is "how much
of a 27B fits on this board, and how fast it runs", not just pass/fail.
