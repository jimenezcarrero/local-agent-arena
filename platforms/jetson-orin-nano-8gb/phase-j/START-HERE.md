# Running the close-out batch

Four stages (J1–J4, about 2.5–4 hours each), **headless, with Claude Code
exited**. After each stage the board resumes the campaign's Claude session by
itself, headless, to review the stage: it pushes `phase-j/review-J<n>.md` with a
go/no-go recommendation and stops. **Nothing runs after that until you start
the next stage.** Details in [`README.md`](README.md).

Login details and addresses are in [`../CONNECT.md`](../CONNECT.md) (placeholders; the real
values are in `~/board-access.local.md` on the board).

The queue refuses to start unless every condition below holds, and says which
one failed.

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

## 3. Start J1, then exit Claude Code

```bash
cd ~/Repositories/local-agent-arena/platforms/jetson-orin-nano-8gb/phase-j
./start_stage.sh J1        # returns at once; J1 waits for Claude Code to exit
```
Type `/exit` in the Claude session. Then, at the board's own keyboard,
`sudo systemctl isolate multi-user.target` (or over SSH). The monitor drops to
a text login. J1 starts within 30 seconds of Claude exiting; you can log out.

## 4. While a stage runs

```bash
cat ~/closeout-status.txt          # one line per step: queued, starting, exit codes, review
tail -3 ~/closeout-J1.log
```
Results are pushed to the `jetson-closeout` branch as each model finishes.
Don't start Claude Code on the board mid-stage: it takes back the memory the
runs are using, and the automatic review won't start while another Claude is
running.

## 5. After each stage

`~/closeout-status.txt` ends with `review finished`, and `phase-j/review-J1.md`
is on GitHub. Read it. To continue, run the command at its end, e.g.
`./start_stage.sh J2`. If the review says NO-GO, or says the review didn't
start, resume the session yourself (`cd ~/Repositories && claude --resume`) and
ask for the review.

## 6. When you're done

```bash
sudo systemctl isolate graphical.target      # desktop back
cd ~/Repositories && claude --resume         # "phase J finished": write-up and PR
```
