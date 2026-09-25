# Review of stage J1 — 2026-09-25

*Written by the automatic hand-off (Claude Code resumed headless), as
`review-prompt.md` asks. Nothing was started by this review.*

## What happened: J1 did not run

| Time (+02:00) | Event (`~/closeout-status.txt`, `~/closeout-J1.log`) |
|---|---|
| 14:50:12 | `start_stage.sh J1` queued; no Claude Code process, so it started at once |
| 14:50:12 | `run_closeout.sh J1`: **`REFUSING TO START: the desktop is running (~1.4GB)`** — exit 2 |
| 14:50:17 | publisher: `queue gone before j-k2h37-r1 finished` (nothing to publish) |
| 14:50:17 | no stage-start marker, so no OOM-exposure file was written |
| 14:50:17 | headless review started (this document) |

Verified afterwards: no `j-` lines in `~/bench-runs/results.txt`, no `j-*` run
directories, no stage marker. At review time the desktop is still active
(`graphical.target` active, a session on seat0/tty2).

**Cause.** `start_stage.sh` waits only for Claude Code to exit. The launch
guide has you `/exit` first and switch the desktop off second, so the stage
started in the gap between the two, and the guard did its job and refused.
No run was made under the wrong conditions.

## The README's J1 questions

None can be answered: no run took place.

| Question | Status |
|---|---|
| K2-Horizon-3.7B marathon + 32K crusher ×3 | not run |
| Ornith-1.5 @65K marathon ×3 | not run |
| NeoHorse-1-4B vendor 32K crusher ×3 | not run |

Nothing to audit: no restarts, no `Connection error.` turns, no rc=124, no
GATE, no guard result.

## What this did establish (infrastructure)

- **The automatic hand-off works end to end.** Five seconds after the queue
  exited, `handoff.sh` resumed the campaign session headless with the review
  prompt. That was the first live test, and it passed.
- **The start guard works.** It caught the desktop and refused; the other
  checks (persistent journal, kernel log readable, linger, the #13 audit fix)
  passed, since the guard checks them first.
- **The journal is persistent** (`/var/log/journal/`), and lingering is on.
  The audit's live past-boot test is still pending: it needs a batch that runs.

## Recommendation: NO-GO for J2 — re-run J1 instead

By the go/no-go rule, J2 is not recommended: J1's queue exited 2 and none of
its questions were answered. The fault is procedural, not a harness or
environment fault, so the right next step is simply to **start J1 again,
with the desktop already off**.

Steps (no script change needed):

1. At the board's keyboard, from the desktop: `sudo systemctl isolate multi-user.target`
   (this review will have exited by then; no Claude Code is running).
2. Log in on the text console.
3. Start J1 there — it starts at once, since Claude isn't running:
   ```bash
   cd ~/Repositories/local-agent-arena/platforms/jetson-orin-nano-8gb/phase-j && ./start_stage.sh J1
   ```
4. A minute later, `./progress.sh` should show `starting` among the last
   events and `J1  0/9   running: j-k2h37-r1`.

## Proposal (not applied: scripts are not changed during a review)

Make `start_stage.sh` wait for the desktop too, not only for Claude Code:
extend its wait loop to `while pgrep -x claude || systemctl is-active -q
graphical.target; do sleep 30; done`, logging which one it is waiting for.
Then the original order (queue, `/exit`, go headless) works, and a stage can
never start in the gap. Until then, use the order above: headless first,
then `start_stage.sh`.
