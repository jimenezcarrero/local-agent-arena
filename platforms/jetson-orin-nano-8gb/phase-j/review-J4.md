# Review of stage J4 — 2026-09-26

*Written by the automatic hand-off (Claude Code resumed headless). Nothing was
started by this review.*

J4 (narrowed before any measurement, #18: Bonsai-27B arenas 1–2 ×3, crusher
dropped) ran **17:09–18:05**, headless, Claude Code exited. All three repeats
completed and were published (`6376a5c`, `56fcb5a`, `2c506a8`).

## The exit code 2 is a second launch, not a failure of this stage

Two `start_stage.sh J4` instances ran:

| Time | What happened |
|---|---|
| 17:07 | Instance 1 queued; it started at 17:09 and ran the whole stage. |
| 17:59 | **Instance 2 launched while instance 1 was mid-run** (Bonsai repeat 3). Its guard refused at once: `REFUSING TO START: a llama-server is already running` (exit 2). Its publisher then waited on the other instance's queue and published nothing; it committed an exposure file and the restart-causes file, and started this review. |
| 18:05–18:06 | Instance 1 finished: queue exit 0, publisher done, exposure committed (`ace00e8`). Its hand-off saw this review running and **correctly did not start a second one**. Its "restart-causes commit FAILED" line is benign: instance 2 had already committed the identical file. |

So the guard did its job: nothing ran twice and no run overlapped another.
One cost: each instance truncates `~/closeout-J4.log` and the publisher log
at start, so **instance 1's own log lines were lost**. The ledger, the
published runs and the status file (which appends) carry the full record,
so no measurement evidence is missing. See proposal 1.

## Audit

- **OOM exposure** (`oom-exposure-J4.txt`): 0 of 6 runs overlapped a kill,
  0 unknown. The raw kernel log for 17:09–18:06 holds no kill either.
- **Restart causes** (`restart-causes-J4.txt`): no restarts in any run.
- No timeouts, no `Connection error.` turns, no GATE, every guard INTACT.
- **Memory ran close to the limit**: the swap sampler's minimum was 61MB
  available, with 608MB of 2,047MB swap still free (never exhausted). That is
  consistent with a 6.8GB server on a 7.5GB board, and why the crusher was
  dropped.

## The README's J4 question: Bonsai-27B on short tasks, scored by the frozen rule

All three attempts are new and headless (its August runs predate this
harness).

| Arena | Runs (s) | Result | Conditions |
|---|---|---|---|
| 1 | 252 · 599 · 743 | **3/3, median 599s** | headless |
| 2 | 471 · 564 · 629 | **3/3, median 564s** | headless |

- **Bonsai passes every short task**: 6 of 6, no interruptions. The 27B
  1-bit model is usable on this board for one-shot work; it is slow, not
  unreliable.
- **Where it ranks** against J3's frozen medians: arena 1, **last of 11**
  ranked cells (Spark Q8 is next at 295s, half its time); arena 2, **9th of
  10** at 564s, ahead of NeoHorse-1-4B vendor (592s, 2/3). This is its
  ~5.3 tok/s decode showing: the time goes into generation, not failures.
- Its August single runs (494s and 603s) sit inside the same range; the
  medians confirm them rather than overturning them.
- Its **long-context workload stays "does not fit cleanly on this 8GB
  tier"**, per the precommitted stop condition. J4 did not test it.

## Recommendation: Phase J is complete

J4 is the last stage, so there is no next stage to recommend and no command
to run. By the go/no-go rule's own checks the stage is sound: instance 1's
queue exited 0, every tag completed, every run is published, the exposure
file has no `unknown` row, and the only fault (the duplicate launch) was
caught by the guard without touching a measurement.

**Next is the Jetson write-up**, not a stage: the platform README's results,
the chart redrawn from the frozen medians with pass counts and the
mixed-condition marks (`review-J3.md`), Bonsai's crusher shown as "does not
fit cleanly", and a PR from `jetson-closeout` to `main`.

## Proposals (not applied: scripts are not changed during a review)

1. **`start_stage.sh` should refuse a second launch of a stage that is
   already queued or running**, with a lock file, instead of reaching the
   queue guard. It should also append to its logs rather than truncate
   them, so a duplicate can't erase the first instance's record.
2. The hand-off worked as designed under the duplicate: two reviews on one
   session were prevented. Worth keeping the "Claude already running" check
   exactly as it is.
