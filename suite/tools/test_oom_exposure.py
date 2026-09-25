"""Regression tests for oom_exposure.py, run against synthetic journals.

A fake `journalctl` on PATH serves a fixture (boots, entries, and which queries
fail or which journal the account can read); OOM_PROC_ROOT supplies the boot
id and btime. Every test asserts on the tool's real output and exit code.

    python3 -m pytest suite/tools/test_oom_exposure.py   (or: python3 -m unittest)
"""
import json, os, subprocess, sys, tempfile, textwrap, time, unittest

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "oom_exposure.py")
KILL = "Out of memory: Killed process 4242 (llama-server) total-vm:9000000kB"

FAKE = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import json, os, sys
    fx = json.load(open(os.environ["FAKE_JOURNAL"]))
    a = sys.argv[1:]
    fail = fx.get("fail", {})
    system = "--system" in a and fx.get("system_access", True)
    def out(entries):
        for e in entries:
            print(json.dumps(e))
    def entry(b, e):
        return {"_BOOT_ID": b["id"], "__MONOTONIC_TIMESTAMP": str(e["mono"]),
                "__REALTIME_TIMESTAMP": str(e["rt"]), "MESSAGE": e["msg"],
                **({"_TRANSPORT": "kernel"} if e.get("kernel") else {})}
    if "--list-boots" in a:
        if fail.get("list"): sys.exit(1)
        # boots are visible either way: the user journal records them too
        print(json.dumps([{"index": i, "boot_id": b["id"]} for i, b in enumerate(fx["boots"])]))
    elif "_TRANSPORT=kernel" in a:
        if fail.get("kernel") == "partial":   # printed some entries, then failed
            out(entry(b, e) for b in fx["boots"] for e in b["entries"] if e.get("kernel") and "Killed" not in e["msg"])
            sys.exit(1)
        if fail.get("kernel"): sys.exit(1)
        if system:
            out(entry(b, e) for b in fx["boots"] for e in b["entries"] if e.get("kernel"))
    elif "-b" in a:
        if fail.get("last"): sys.exit(1)
        b = next(b for b in fx["boots"] if b["id"] == a[a.index("-b") + 1])
        out([entry(b, b["entries"][-1])] if system else [])
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
        self.btime = int(self.now - 10_000)        # running boot started 10,000s ago
        self.cur = "c" * 32
        with open(f"{self.tmp}/proc/sys/kernel/random/boot_id", "w") as f:
            f.write("cccccccc-cccc-cccc-cccc-cccccccccccc\n")
        with open(f"{self.tmp}/proc/stat", "w") as f:
            f.write(f"cpu  1 2 3\nbtime {self.btime}\n")
        self.fixture = {"boots": [self.boot(self.cur, self.btime, [(1, "Linux version"),
                                                                  (9_000, "last kernel msg")])]}

    def boot(self, bid, start, kernel_msgs, stale_clock=False):
        """A boot whose entries sit at `start + offset`. With stale_clock, the
        early entries carry a July-2026 wall time, as on the Jetson."""
        entries = []
        for off, msg in kernel_msgs:
            rt = (1785251085 + off) if stale_clock and off < 60 else start + off
            entries.append({"mono": int(off * 1e6), "rt": int(rt * 1e6), "msg": msg, "kernel": True})
        return {"id": bid, "entries": entries}

    def kill_at(self, t, bid=None, start=None):
        b = next(b for b in self.fixture["boots"] if b["id"] == (bid or self.cur))
        off = t - (start if start is not None else self.btime)
        b["entries"].insert(-1, {"mono": int(off * 1e6), "rt": int(t * 1e6), "msg": KILL, "kernel": True})

    def run_dir(self, name, start, end, date=None):
        d = f"{self.tmp}/runs/arena3/{name}"; os.makedirs(d)
        with open(f"{d}/env.txt", "w") as f:
            f.write(f"date: {date or time.strftime('%Y-%m-%dT%H:%M:%S%z', time.localtime(start))[:-2] + ':' + time.strftime('%z', time.localtime(start))[-2:]}\n")
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

    # --- the #11 fix: coverage runs to now, not to the last kernel message
    def test_run_after_last_kernel_message_is_covered(self):
        self.run_dir("after", self.now - 300, self.now - 60)   # last kernel msg was at btime+9000
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

    # --- review finding 1: a failed query must not read as "no kills"
    def test_failed_kernel_query_is_an_error(self):
        self.kill_at(self.now - 200)
        self.run_dir("hit", self.now - 300, self.now - 60)
        self.fixture["fail"] = {"kernel": True}
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)

    def test_kernel_query_failing_partway_is_an_error(self):
        self.kill_at(self.now - 200)
        self.run_dir("hit", self.now - 300, self.now - 60)
        self.fixture["fail"] = {"kernel": "partial"}
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)

    def test_failed_boot_listing_is_an_error(self):
        self.run_dir("r", self.now - 300, self.now - 60)
        self.fixture["fail"] = {"list": True}
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)

    def test_failed_past_boot_query_is_an_error(self):
        prev = "p" * 32
        self.fixture["boots"].insert(0, self.boot(prev, self.btime - 50_000, [(1, "Linux version"), (100, "x")]))
        self.run_dir("r", self.now - 300, self.now - 60)
        self.fixture["fail"] = {"last": True}
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)

    # --- review finding 2: user-journal access is not kernel-history access
    def test_no_system_journal_access_is_an_error(self):
        self.kill_at(self.now - 200)
        self.run_dir("hit", self.now - 300, self.now - 60)
        self.fixture["system_access"] = False
        rc, out = self.audit()
        self.assertNotEqual(rc, 0, out); self.assertNotIn("oom_kills=0", out)
        self.assertIn("system journal", out)

    # --- review finding 3: the recorded UTC offset decides the window
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

    # --- the past-boot path, with the Jetson's stale early-boot clock
    def test_past_boot_is_covered_and_its_kills_counted(self):
        prev, pstart = "p" * 32, self.btime - 50_000                # ran 50,000s before this boot
        self.fixture["boots"].insert(0, self.boot(prev, pstart, [(1, "Linux version"), (30_000, "late")],
                                                  stale_clock=True))
        self.kill_at(pstart + 20_000, bid=prev, start=pstart)
        self.run_dir("prev-hit", pstart + 19_000, pstart + 21_000)
        self.run_dir("prev-clean", pstart + 25_000, pstart + 26_000)
        self.run_dir("between-boots", pstart + 35_000, pstart + 36_000)   # after its last entry
        rc, out = self.audit()
        self.assertEqual((self.kills(out, "prev-hit"), self.kills(out, "prev-clean"),
                          self.kills(out, "between-boots")), ("1", "0", "unknown"), out)

    def test_past_boot_without_readable_kernel_entries_covers_nothing(self):
        prev, pstart = "p" * 32, self.btime - 50_000
        b = self.boot(prev, pstart, [(1, "Linux version"), (30_000, "late")])
        for e in b["entries"]:
            e["kernel"] = False                                     # only non-kernel entries retained
        self.fixture["boots"].insert(0, b)
        self.run_dir("prev", pstart + 19_000, pstart + 21_000)
        rc, out = self.audit()
        self.assertEqual((rc, self.kills(out, "prev")), (1, "unknown"), out)


if __name__ == "__main__":
    unittest.main()
