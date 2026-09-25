# Running the close-out batch

About **13 hours**, unattended, headless, **with Claude Code exited**.
Login details and addresses are in [`../CONNECT.md`](../CONNECT.md) (placeholders; the real
values are in `~/board-access.local.md` on the board).

The queue refuses to start unless every condition below holds, and says which
one failed. Nothing runs until they all pass.

## 1. Once, with sudo (from the desktop terminal)

```bash
# durable kernel log: the reason phases B, C and H have no kill records
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
journalctl --header | grep -m1 'File path'    # must show /var/log/journal/...

# let the batch survive logout (the 2026-09-24 reboot reset this)
sudo loginctl enable-linger $USER
loginctl show-user $USER -p Linger            # Linger=yes
```

## 2. Get the code

Merge PR #13 on GitHub first (the batch's OOM audit depends on it). Then:

```bash
cd ~/Repositories/local-agent-arena
git fetch && git checkout jetson-closeout && git pull
git merge --no-edit origin/main && git push    # brings in #13
grep -c btime suite/tools/oom_exposure.py      # must be ≥1, or the batch refuses
```

## 3. Exit Claude Code

Type `/exit` in the Claude session. The conversation is saved; step 6 resumes it.

## 4. Go headless and start the batch

At the board's own keyboard: `sudo systemctl isolate multi-user.target`. The
monitor drops to a text login; log in there. (Or do the same over SSH.)

```bash
cd ~/Repositories/local-agent-arena/platforms/jetson-orin-nano-8gb/phase-j
setsid nohup ./run_closeout.sh    > ~/closeout.log         2>&1 < /dev/null &
sleep 10; head -3 ~/closeout.log      # must say "=== Phase J start", not "REFUSING"
setsid nohup ./publish_results.sh > ~/closeout-publish.log 2>&1 < /dev/null &
```

You can log out; the batch keeps running. Each model's results are committed
and pushed to the `jetson-closeout` branch as it finishes, so progress is
visible on GitHub from anywhere.

## 5. Checking on it

```bash
tail -3 ~/closeout.log; tail -2 ~/closeout-publish.log
~/Repositories/local-agent-arena/suite/tools/healthcheck.sh
```
Don't start Claude Code on the board to check — it takes back the memory the
batch is running in. Checking from the laptop over SSH, or on GitHub, is fine.

## 6. When it's done

`~/closeout.log` ends with `=== Phase J done` and the `oom_exposure exit=` line.

```bash
sudo systemctl isolate graphical.target      # desktop back
cd ~/Repositories && claude --resume         # pick this session, say "phase J finished"
```
Then the write-up: results into `README.md` here, the chart, and a PR to `main`.
