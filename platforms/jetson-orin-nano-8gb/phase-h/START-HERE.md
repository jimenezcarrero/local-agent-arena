# Running the board headless

Login details, addresses and how to resume a Claude session after a reboot:
[`../CONNECT.md`](../CONNECT.md).

With a desktop session up, ~1.4GB is held by gnome-shell, Xorg and the
terminal, and any model over ~4.5GB gets its long runs OOM-killed: 78 kills
damaged 37 of 85 runs in phases A and B. Logged out, those cells are
measurable. This is the batch that needs it.

## Before logging out (run these once, from the desktop terminal)

```bash
sudo systemctl enable --now ssh     # SSH is currently off; you need a way back in
sudo loginctl enable-linger $USER   # let detached jobs survive logout (currently off)
ip -4 addr show | grep -oP '(?<=inet )192[^/]+'   # note the address (<board-address>)
```

## Going headless (from the laptop)

```bash
ssh <user>@<hostname>.local
sudo systemctl isolate multi-user.target          # stops GNOME, frees ~1.4GB
free -m                                           # expect ~6.5GB available
setsid nohup ~/Repositories/local-agent-arena/platforms/jetson-orin-nano-8gb/phase-h/run_headless.sh \
  > ~/headless.log 2>&1 < /dev/null &
setsid nohup ~/Repositories/local-agent-arena/platforms/jetson-orin-nano-8gb/phase-h/publish_results.sh \
  > ~/headless-publish.log 2>&1 < /dev/null &
exit                                              # the batch keeps running
```

Or, instead of the two `setsid` lines, start Claude Code over SSH and say
"continue the headless batch" — it will launch and supervise it.

## Watching it

```bash
ssh <user>@<hostname>.local 'tail -5 ~/headless.log; \
  ~/Repositories/local-agent-arena/platforms/jetson-orin-nano-8gb/phase-h/healthcheck.sh'
```
Results also appear on GitHub: each model is committed and pushed as it finishes.

## Coming back to the desktop

```bash
ssh <user>@<hostname>.local 'sudo systemctl isolate graphical.target'
```
The batch keeps running (it is detached and lingering is enabled), though the
larger models may start being OOM-killed again once the desktop is back.

## What the batch covers, in order

1. Ornith-1.0 at 65K, default vs published sampling, 3 runs each — the champion
   row; all six 65K runs so far were OOM-damaged
2. Ornith-1.0's 131K crusher — failed to allocate its KV cache twice
3. K2-Horizon-7B IQ3_XXS full ladder — 5.56GB, never attempted
4. gemma-E4B @98K with its MTP draft — open since August
5. Ornith-1.5 at 65K, default and vendor sampling — never loaded at all
6. Bonsai-27B's three session re-runs — never redone after the cascade audit
7. K2-3.7B crusher repeats, to finish that cell cleanly

About 20-23 hours end to end. The order is deliberate: an interrupted batch
still delivers the champion row first.
