# Review of stage J1 — 2026-09-25

*Written by the automatic hand-off (Claude Code resumed headless). Nothing was
started by this review.*

J1 ran 15:02–22:29 (a first attempt at 14:50 never started: the desktop was
still up and the start guard refused). Queue exit 0, all 9 steps done, all 12
runs published. Headless, Claude Code exited, 6,642MB free at start, no
suspend during the stage.

## ⚠ The OOM-exposure file is wrong: 11 kills reported as 0

`oom-exposure-J1.txt` says **0 of 12 runs overlapped a kill**. The kernel log
recorded **11 OOM kills of llama-server during J1**, every one inside a run
(table below). This is a false zero, the failure the tool exists to prevent.

**Cause, established:** the board **suspended from 2026-09-24 23:54 to
2026-09-25 07:27** (`PM: suspend entry/exit`). `oom_exposure.py` dates each
kill as *btime + the entry's monotonic timestamp*. btime comes from the boot
clock, which counts suspended time; journald's monotonic clock does not. After
the suspend, every kill landed 27,205s (7.56h, exactly the suspend) early:
the 15:35:11 kill was placed at 08:01:46, before J1 began. `CLOCK_BOOTTIME −
CLOCK_MONOTONIC` on the board is 27,205s. The #13 regression tests never
modelled a suspend.

**Evidence is intact.** The journal is persistent and every kill is on record.
The attribution below uses each kill's own wall-clock timestamp, which is
correct here: NTP had long synced, and the wall clock agrees with the ledger.

| Run | Kills (wall time) | Restarts | What the kill hit |
|---|---|---|---|
| j-k2h37-r1-a3 | — | 0 | clean |
| j-k2h37-r1-a4-32k | 15:35:11 | 1 | turn 6 cut short (peak_slot_ctx=0) |
| j-k2h37-r2-a3 | 16:41:27 | 2 | turn 10 cut (FAIL); see below for turn 11 |
| j-k2h37-r2-a4-32k | 17:20:51, 18:02:28 | 2 | turns 4 and 7 cut (peak_slot_ctx=0) |
| j-k2h37-r3-a3 | 18:56:18 | 1 | 1s after turn 10 hit the 600s cap |
| j-k2h37-r3-a4-32k | 19:37:07 | 1 | one turn cut |
| j-ornith15-65k-r1-a3 | 20:19:47 | 1 | turn 6 never reached the model (`Connection error.`) |
| j-ornith15-65k-r2-a3 | 20:37:54 | 1 | turn 2 never reached the model |
| j-ornith15-65k-r3-a3 | 21:13:37 | 1 | turn 6 never reached the model |
| j-neohorse-vp-r1-a4-32k | — | 0 | clean |
| j-neohorse-vp-r2-a4-32k | 22:00:33 | 1 | turn 5 never reached the model |
| j-neohorse-vp-r3-a4-32k | 22:19:47 | 1 | turn 5 never reached the model |

Every kill logged `Free swap = 0kB`; the killed servers held 6.3–6.6GB
anonymous RSS. 12 restarts: 11 follow a kill; the 12th is
`j-k2h37-r2-a3`'s turn 11, which hit the 600s cap right after the restart
(below).

## The README's J1 questions

Scores are the observed ones; interruptions are listed beside them, per the
suite's interruption policy.

**K2-Horizon-3.7B — does "fastest perfect marathon (9m06s)" hold?**

| Run | Marathon | 32K crusher |
|---|---|---|
| r1 | **11/11 in 12m57s, uninterrupted** | full pass, 48m33s — 1 kill (turn 6) |
| r2 | 9/11 — 1 kill (turn 10), then turn 11 timed out | **fail on every check** (pytest, both anchors, FUNCTIONS.md), 81m17s, 8 compactions — 2 kills (turns 4, 7) |
| r3 | 11/11 in 48m45s — turn 10 hit the 600s cap (tests green), 1 kill 1s later | full pass, 63m42s — 1 kill |

- r2's turn 11 started on a freshly restarted server with an empty prompt
  cache, re-read 35,796 prompt tokens, stopped writing output at 16:41:58 and
  hit the 600s cap. The restart caused the cold re-read; whether the model
  would have finished with a warm cache can't be told from these logs.
- r3: the cap at 18:56:17 and the kill at 18:56:18 are 1s apart; which came
  first can't be resolved at 1-second resolution.
- **Answer:** J1's only uninterrupted marathon was a perfect 11/11 in
  **12m57s**, not 9m06s. The 9m06s stays a single observation from phase B.
  Across J1, K2 took **6 kills in 6 runs** even with the board fully free: a
  3.7B model at 32K is not kill-free on this board.

**Ornith-1.5 @65K, marathon ×3 — do the kills stop with Claude's memory back?**

**No.** 10/11 in all three runs (18m55s, 23m23s, 29m37s), and each lost
exactly one turn to a kill that never reached the model (turns 6, 2, 6). Every
other turn passed. The phase-H pattern (always turn 2) did not repeat: here
the kill came at turn 6 twice. With the board fully free, Ornith-1.5 at 65K
still runs out of memory once per marathon, so the withdrawn Ornith ranking
cannot become a clean comparison on this board.

**NeoHorse-1-4B vendor profile, 32K crusher ×3**

r1 **full pass, uninterrupted** (13m35s); r2 pytest and both anchors pass,
FUNCTIONS.md fails — 1 kill, turn 5 never reached the model; r3 full pass — 1
kill, turn 5 never reached the model. **2 full, 1 partial**: the same shape as
phase A's cell, now with kernel-recorded kills (2, not 3) and one clean run.

## Recommendation: NO-GO for J2 until the audit tool is fixed

By the go/no-go rule, J2 is not recommended yet. The queue exited 0, every
tag completed, every run is published, and the exposure file has no
`unknown` row. But the audit found a harness fault: the exposure tool reports
false zeros after a suspend. J2 would get a wrong exposure file too. The
fault is in the audit, not in the runs: the journal is persistent and holds
every kill, so nothing is lost and J1 needs no re-run.

To unblock J2:
1. Fix `oom_exposure.py` (proposal below), with a regression test that puts a
   suspend in the middle of a boot, and merge it the usual way.
2. Regenerate `oom-exposure-J1.txt` from the persistent journal and check it
   against the table above (11 kills in 10 runs).
3. Then J2 is GO: `platforms/jetson-orin-nano-8gb/phase-j/start_stage.sh J2`.

**Looking ahead to J4:** the README says to recommend skipping J4 (Bonsai,
6.8GB) if J1's Ornith-1.5 marathons still took kills with the board fully
free. They did, in all three. The J3 review should recommend skipping J4
unless J2–J3 give a reason to reconsider.

## Proposals (not applied: scripts are not changed during a review)

1. **`oom_exposure.py`: stop adding monotonic time to btime.** Date each kill
   by its own `__REALTIME_TIMESTAMP`. That is right once NTP has synced, and
   the board's stale-clock entries are recognisable: their wall time falls
   before the boot's real start (btime, for the running boot). Coverage has
   the same flaw (`start + first_mono`) and needs the same treatment; a past
   boot's start (`last_rt − last_mono`) is also wrong if that boot suspended.
   Add tests for a suspend inside the running boot and inside a past boot.
2. **Keep the board awake during a batch.** The overnight suspend came from
   the desktop session. J1 ran headless and didn't suspend, but wrapping
   `run_closeout.sh` in `systemd-inhibit --what=sleep:idle` (as the laptop
   runbook does) would make that certain.
3. *(carried over)* Make `start_stage.sh` also wait until the desktop is off,
   so a stage can't start in the gap between `/exit` and going headless.

## Resolution (added 2026-09-25, interactive session)

- **Audit tool fixed** in PR #14 (`suite-oom-suspend`): kills and runs are
  matched within clock segments, so a suspend can't move a kill; runs record
  `boot_id:`; 18 regression tests, including a suspend in the running boot.
- **`oom-exposure-J1.txt` regenerated** with that tool from the same persistent
  journal: **11 kills in 10 runs**, identical run by run to the attribution
  table above.
- **Proposal 1** done (above). **Proposal 2** (keep the board awake): a
  `systemd-inhibit` wrapper is not possible, because polkit refuses this
  account a sleep lock (`Access denied`). The overnight suspend was requested
  from the desktop session, which stages now require to be off, and the start
  guard refuses unless logind's `IdleAction` is `ignore` (it is). That removes
  the known idle and desktop paths, not every one: an explicit request, a
  suspend key or a lid switch could still suspend the board, and if one does,
  the audit marks the affected run `unknown` rather than miscounting it.
  **Proposal 3** done: `start_stage.sh` now waits for the desktop to be off
  as well as for Claude Code to exit.
- With PR #14 merged into `main` and `main` merged into `jetson-closeout`, J2
  is GO:

```bash
platforms/jetson-orin-nano-8gb/phase-j/start_stage.sh J2
```
