"""Regression tests for oom_exposure.py, run against synthetic journals.

A fake `journalctl` on PATH serves a fixture (boots in order, their entries,
which queries fail, and whether the account can read the system journal);
OOM_PROC_ROOT supplies the running boot's id and btime. Every test asserts on
the tool's real output and exit code.

Entries carry a wall-clock stamp and a monotonic one, as journald's do: the
monotonic clock stops during a suspend, the wall clock doesn't, and a board
without an RTC battery stamps early-boot entries with a stale wall clock.

    python3 -m pytest suite/tools/test_oom_exposure.py   (or: python3 -m unittest)
"""
import json, os, subprocess, sys, tempfile, textwrap, time, unittest

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "oom_exposure.py")
KILL = "Out of memory: Killed process 4242 (llama-server) total-vm:9000000kB"
STALE = 1785251085  # the Jetson's early-boot wall clock: 2026-07-28

FAKE = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import json, os, sys
    fx = json.load(open(os.environ["FAKE_JOURNAL"]))
    a = sys.argv[1:]
    fail = fx.get("fail", {})
    system = "--system" in a and fx.get("system_access", True)
    def out(rows):
        for r in rows:
            print(json.dumps(r))
    def entry(b, e):
        return {"_BOOT_ID": b["id"], "__MONOTONIC_TIMESTAMP": str(int(e["mono"] * 1e6)),
                "__REALTIME_TIMESTAMP": str(int(e["rt"] * 1e6)), "MESSAGE": e["msg"]}
    if "--list-boots" in a:
        if fail.get("list"): sys.exit(1)
        # boots are visible either way: the user journal records them too
        print(json.dumps([{"index": i - len(fx["boots"]) + 1, "boot_id": b["id"]}
                          for i, b in enumerate(fx["boots"])]))
    elif "_TRANSPORT=kernel" in a:
        rows = [entry(b, e) for b in fx["boots"] for e in b["entries"] if e.get("kernel")]
        if fail.get("kernel") == "partial":   # printed some entries, then failed
            out(r for r in rows if "Killed" not in r["MESSAGE"]); sys.exit(1)
        if fail.get("kernel"): sys.exit(1)
        if system: out(rows)
    elif any(x.startswith("--output-fields") for x in a):
        if fail.get("all"): sys.exit(1)
        if system: out(entry(b, e) for b in fx["boots"] for e in b["entries"])
    else:
        sys.exit(2)
''').lstrip()


class OomExposure(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        os.makedirs(f"{self.tmp}/bin"); os.makedirs(f"{self.tmp}/proc/sys/kernel/random")
        with open(f"{self.tmp}/bin/journalctl", "w") as f:
            f.write(FAKE)
        os.chmod(f"{self.tmp}/bin/journalctl", 0o755)
        self.now = time.time()
        self.btime = self.now - 10_000             # running boot started 10,000s ago
        self.cur = "c" * 32
        with open(f"{self.tmp}/proc/sys/kernel/random/boot_id", "w") as f:
            f.write("cccccccc-cccc-cccc-cccc-cccccccccccc\n")
        with open(f"{self.tmp}/proc/stat", "w") as f:
            f.write(f"cpu  1 2 3\nbtime {int(self.btime)}\n")
        self.fixture = {"boots": [self.boot(self.cur, self.btime, 9_900)]}

    def boot(self, bid, start, length, stale=False, suspend=None, kernel_after=0):
        """Entries every 100s of boot time from `start` for `length` seconds of
        wall time. stale: the first 60s carry a wrong (July 2026) wall clock.
        suspend=(at, dur): asleep for `dur` wall seconds starting at wall
        offset `at`; the monotonic clock doesn't advance meanwhile.
        kernel_after: kernel entries were rotated away before this offset."""
        entries, off = [], 1.0
        at, dur = suspend or (float("inf"), 0)
        while off <= length:
            if at <= off < at + dur:
                off = at + dur                     # nothing is logged while asleep
            mono = off - (dur if off >= at + dur else 0)
            rt = STALE + off if stale and off < 60 else start + off
            k = (off < 10 or off % 1000 < 100) and off >= kernel_after
            entries.append({"mono": mono, "rt": rt, "msg": "tick", "kernel": k})
            off += 100 if not (stale and off < 60) else 20
        return {"id": bid, "entries": entries, "start": start, "suspend": [at, dur]}

    def kill_at(self, t, bid=None):
        b = next(b for b in self.fixture["boots"] if b["id"] == (bid or self.cur))
        at, dur = b["suspend"]
        off = t - b["start"]
        mono = off - (dur if off >= at + dur else 0)
        b["entries"].append({"mono": mono, "rt": t, "msg": KILL, "kernel": True})
        b["entries"].sort(key=lambda e: e["mono"])

    def run_dir(self, name, start, end, date=None, boot=None):
        d = f"{self.tmp}/runs/arena3/{name}"; os.makedirs(d)
        if date is None:
            z = time.strftime("%z", time.localtime(start))
            date = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(start)) + z[:3] + ":" + z[3:]
        with open(f"{d}/env.txt", "w") as f:
            f.write(f"date: {date}\n" + (f"boot_id: {boot}\n" if boot else ""))
        os.utime(f"{d}/env.txt", (end, end))

    def audit(self, tz=None):
        with open(f"{self.tmp}/fixture.json", "w") as f:
            json.dump(self.fixture, f)
        env = {"PATH": f"{self.tmp}/bin:/usr/bin:/bin", "OOM_PROC_ROOT": f"{self.tmp}/proc",
               "FAKE_JOURNAL": f"{self.tmp}/fixture.json", "TZ": tz or "Europe/Madrid", "HOME": self.tmp}
        r = subprocess.run([sys.executable, TOOL, "2000-01-01", f"{self.tmp}/runs"],
                           capture_output=True, text=True, env=env)
        return r.returncode, r.stdout + r.stderr

    def kills(self, out, name):
        line = next(l for l in out.splitlines() if l.startswith(name + " "))
        return line.split("oom_kills=")[1].split()[0]

    def add_past_boot(self, bid, start, length, **kw):
        b = self.boot(bid, start, length, **kw)
        self.fixture["boots"].insert(len(self.fixture["boots"]) - 1, b)
        return b

    # --- coverage basics
    def test_run_after_last_kernel_message_is_covered(self):
        self.run_dir("after", self.now - 300, self.now - 60)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "after")), (0, "0"), out)

    def test_kill_inside_window_is_counted(self):
        self.kill_at(self.now - 200)
        self.run_dir("hit", self.now - 300, self.now - 60)
        self.run_dir("miss", self.now - 3000, self.now - 2500)
        rc, out = self.audit()
        self.assertEqual((self.kills(out, "hit"), self.kills(out, "miss")), ("1", "0"), out)

    def test_run_before_the_boot_is_unknown(self):
        self.run_dir("old", self.btime - 5000, self.btime - 4000)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "old")), (1, "unknown"), out)

    # --- failed or partial queries are errors, never "no kills"
    def test_failed_kernel_query_is_an_error(self):
        self.kill_at(self.now - 200); self.run_dir("hit", self.now - 300, self.now - 60)
        self.fixture["fail"] = {"kernel": True}
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)

    def test_kernel_query_failing_partway_is_an_error(self):
        self.kill_at(self.now - 200); self.run_dir("hit", self.now - 300, self.now - 60)
        self.fixture["fail"] = {"kernel": "partial"}
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)

    def test_failed_boot_listing_is_an_error(self):
        self.run_dir("r", self.now - 300, self.now - 60)
        self.fixture["fail"] = {"list": True}
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)

    def test_failed_full_journal_query_is_an_error(self):
        self.run_dir("r", self.now - 300, self.now - 60)
        self.fixture["fail"] = {"all": True}
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)

    # --- a readable user journal is not kernel-history access
    def test_no_system_journal_access_is_an_error(self):
        self.kill_at(self.now - 200); self.run_dir("hit", self.now - 300, self.now - 60)
        self.fixture["system_access"] = False
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)
        self.assertIn("system journal", out)

    # --- run windows keep their UTC offset
    def test_offset_is_kept_when_auditing_in_another_zone(self):
        start = self.now - 300
        local = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(start + 7200))   # wall time at +02:00
        self.kill_at(self.now - 200)
        self.run_dir("tz", start, self.now - 60, date=local + "+02:00")
        rc, out = self.audit(tz="UTC")
        self.assertEqual((rc, self.kills(out, "tz")), (0, "1"), out)

    def test_start_without_offset_is_unknown(self):
        self.run_dir("naive", self.now - 300, self.now - 60,
                     date=time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(self.now - 300)))
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "naive")), (1, "unknown"), out)

    def test_window_that_ends_before_it_starts_is_unknown(self):
        self.run_dir("inverted", self.now - 60, self.now - 300)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "inverted")), (1, "unknown"), out)

    # --- suspends: the J1 false zero (11 real kills read as 0)
    def test_kill_after_a_suspend_in_the_running_boot_is_counted(self):
        # asleep for 3,000s from boot offset 2,000; J1 ran after an overnight suspend
        self.fixture["boots"] = [self.boot(self.cur, self.btime, 9_900, suspend=(2_000, 3_000))]
        self.kill_at(self.now - 200)
        self.run_dir("after-suspend", self.now - 300, self.now - 60)
        self.run_dir("before-suspend", self.btime + 1_000, self.btime + 1_500)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "after-suspend"), self.kills(out, "before-suspend")),
                         (0, "1", "0"), out)

    def test_run_spanning_a_suspend_is_unknown(self):
        self.fixture["boots"] = [self.boot(self.cur, self.btime, 9_900, suspend=(2_000, 3_000))]
        self.run_dir("across", self.btime + 1_500, self.btime + 5_500)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "across")), (1, "unknown"), out)

    def test_kill_after_a_suspend_in_a_past_boot_is_counted(self):
        p1 = "b" * 32
        self.add_past_boot(p1, self.btime - 50_000, 30_000, suspend=(5_000, 8_000))
        self.kill_at(self.btime - 30_000, bid=p1)
        self.run_dir("p1-hit", self.btime - 30_500, self.btime - 29_500, boot=p1)
        rc, out = self.audit()
        self.assertEqual(self.kills(out, "p1-hit"), "1", out)

    # --- kernel history must reach back over the run (review of #14, P1)
    def test_run_before_the_oldest_retained_kernel_entry_is_unknown(self):
        # service entries from the start of the boot, kernel entries only from +5,000s
        self.fixture["boots"] = [self.boot(self.cur, self.btime, 9_900, kernel_after=5_000)]
        self.run_dir("gap", self.btime + 1_000, self.btime + 1_500)
        self.run_dir("after", self.btime + 6_000, self.btime + 6_500)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "gap"), self.kills(out, "after")), (1, "unknown", "0"), out)

    # --- past boots need a boot_id (review of #14, second issue)
    def test_past_boot_run_without_boot_id_is_unknown_even_with_a_predecessor(self):
        p0, p1 = "a" * 32, "b" * 32
        self.add_past_boot(p0, self.btime - 90_000, 10_000)
        self.add_past_boot(p1, self.btime - 50_000, 30_000)
        self.kill_at(self.btime - 30_000, bid=p1)
        self.run_dir("legacy", self.btime - 30_500, self.btime - 29_500)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "legacy")), (1, "unknown"), out)

    def test_successors_stale_clock_cannot_claim_a_past_boots_legacy_run(self):
        # boot A's last retained entry is at T; a legacy run happened at T+1,800
        # (after A's journal stops); boot B's stale early clock reads T+1,200..T+2,400
        a, b = "a" * 32, "b" * 32
        A = self.add_past_boot(a, self.btime - 90_000, 10_000)
        T = A["entries"][-1]["rt"]
        B = self.boot(b, self.btime - 50_000, 30_000)
        # the stale clock ticks in step with the boot clock (one segment), then NTP jumps
        B["entries"][:0] = [{"mono": 1 + i * 200, "rt": T + 1_200 + i * 200, "msg": "stale", "kernel": True}
                            for i in range(7)]
        for e in B["entries"][7:]:
            e["mono"] += 1_400
        self.fixture["boots"].insert(1, B)
        self.run_dir("legacy", T + 1_800, T + 1_900)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "legacy")), (1, "unknown"), out)

    # --- stale early-boot clocks
    def test_stale_clock_segment_does_not_cover_a_lost_boots_run(self):
        # the running boot's first 60s are dated July 2026; a run from a boot
        # whose journal is gone happens to fall inside that stale range
        self.fixture["boots"] = [self.boot(self.cur, self.btime, 9_900, stale=True)]
        self.run_dir("lost-boot", STALE + 5, STALE + 30)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "lost-boot")), (1, "unknown"), out)

    def test_oldest_boot_needs_a_boot_id_to_be_covered(self):
        old = "o" * 32
        self.add_past_boot(old, self.btime - 50_000, 30_000, stale=True)
        self.kill_at(self.btime - 30_000, bid=old)
        self.run_dir("no-id", self.btime - 30_500, self.btime - 29_500)
        self.run_dir("with-id", self.btime - 30_500, self.btime - 29_400, boot=old)
        rc, out = self.audit()
        self.assertEqual((self.kills(out, "no-id"), self.kills(out, "with-id")), ("unknown", "1"), out)

    def test_boot_id_that_the_journal_does_not_hold_is_unknown(self):
        self.run_dir("elsewhere", self.now - 300, self.now - 60, boot="d" * 32)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "elsewhere")), (1, "unknown"), out)

    def test_past_boot_between_boots_is_unknown(self):
        p0, p1 = "a" * 32, "b" * 32
        self.add_past_boot(p0, self.btime - 90_000, 10_000)
        self.add_past_boot(p1, self.btime - 50_000, 30_000)
        self.run_dir("gap", self.btime - 15_000, self.btime - 14_000)   # after p1 ended, before this boot
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "gap")), (1, "unknown"), out)


if __name__ == "__main__":
    unittest.main()
