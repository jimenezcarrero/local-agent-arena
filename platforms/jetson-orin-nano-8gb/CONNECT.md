# Getting back into the board

Everything needed to reach the Jetson and resume work, so it never has to be
found in an old chat again.

## Identity

| | |
|---|---|
| Login user | *(your board user; see the local note below)* |
| Hostname | set at install; avahi is enabled, so `<hostname>.local` resolves on the LAN |
| Wi-Fi address | DHCP on `wlP1p1s0` — find it with `hostname -I` |
| USB-C fallback | the board exposes a device-mode network over USB-C, reachable with just a cable when Wi-Fi is down |
| Password | your own account password (never stored in this repo) |
| OS | JetPack 7.2.1-b49, L4T R39.2.1, Ubuntu 22.04, CUDA 13.2 |
| Repo on board | `~/Repositories/local-agent-arena` |
| Models | `~/Repositories/llama.cpp/models` |

Prefer the `.local` name: it survives a DHCP address change.

```bash
ssh <user>@<hostname>.local     # or the LAN IP, or the USB-C address
```

The actual user, hostname and addresses for this board are in
`~/board-access.local.md` on the board itself (not in this repo, and gitignored).
If mDNS fails, find the address from your router, or connect a screen and run
`hostname -I`.

## Using the attached monitor and keyboard (no SSH needed)

Headless means no desktop, **not** no terminal. `getty@tty1` is enabled, so
after stopping the graphical target the monitor shows a `jetson login:` prompt.
Log in as your board user and you have a full shell; `Ctrl+Alt+F1`..`F6` switch
consoles (the desktop session sits on tty2). Claude Code runs there normally.

SSH is a convenience and a safety net, not a requirement.

## One-time setup (needed before any headless work)

```bash
sudo systemctl enable --now ssh     # otherwise there is no way back in
sudo loginctl enable-linger $USER   # otherwise logout kills detached jobs
```

Lingering is the one that really matters: every job runs inside
`user@2002.service`, and with `Linger=no` systemd tears that cgroup down when
your last session ends — killing the benchmarks, `setsid` or not.
`KillUserProcesses` is already `no` on this board, which is not sufficient on
its own. Both were **off** as of 2026-09-21. Check with `systemctl is-active ssh` and
`loginctl show-user $USER -p Linger`.

## Going headless

Temporary (no reboot, reverts on next boot):

```bash
sudo systemctl isolate multi-user.target     # stops GNOME, frees ~1.4GB
free -m                                      # expect ~6.5GB available
```

Persistent across reboots:

```bash
sudo systemctl set-default multi-user.target
sudo reboot
```

Back to the desktop:

```bash
sudo systemctl isolate graphical.target      # now
sudo systemctl set-default graphical.target  # and for future boots
```

## Resuming Claude Code after a reboot

Sessions are stored per directory, so **start from the same directory** or the
old conversation will not be listed:

```bash
ssh <user>@<hostname>.local
cd ~/Repositories          # session history lives under ~/.claude/projects/<path>
claude --resume            # pick the session from the list
```

To jump straight to a known session: `claude --resume <session-id>`, where the
ids are the filenames in `~/.claude/projects/<your-repo-path>/`
(newest first: `ls -t`). The September 2026 campaign session is
`1981e804-44cf-4c73-af43-ae38db1408a8`.

A reboot kills any running batch (detached jobs do not survive a reboot, only a
logout). Restart it with:

```bash
setsid nohup ~/Repositories/local-agent-arena/platforms/jetson-orin-nano-8gb/phase-h/run_headless.sh \
  > ~/headless.log 2>&1 < /dev/null &
setsid nohup ~/Repositories/local-agent-arena/platforms/jetson-orin-nano-8gb/phase-h/publish_results.sh \
  > ~/headless-publish.log 2>&1 < /dev/null &
```

Runs already finished are safe: each is committed and pushed to GitHub as it
completes, and `~/bench-runs/` keeps every log.

## Checking on it from anywhere

```bash
ssh <user>@<hostname>.local 'tail -5 ~/headless.log; \
  ~/Repositories/local-agent-arena/platforms/jetson-orin-nano-8gb/phase-h/healthcheck.sh'
```

Or read the branch on GitHub: <https://github.com/jimenezcarrero/local-agent-arena/tree/jetson-phase-a>

## Serving models normally (not benchmarking)

```bash
llm start      # llama-server router on :8080, disabled at boot by design
llm pick       # choose a model
llm stop
```
