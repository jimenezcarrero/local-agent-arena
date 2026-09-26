"""Tests for restart_causes.py: a fake journalctl on PATH, a synthetic
vmstat_sampler log, and restarts.log files as the harness writes them."""
import json, os, subprocess, sys, tempfile, textwrap, time, unittest

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "restart_causes.py")
FAKE = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import json, os, sys
    fx = json.load(open(os.environ["FAKE_JOURNAL"]))
    if fx.get("fail"): sys.exit(1)
    a = sys.argv[1:]
    since = float(a[a.index("--since") + 1].lstrip("@")); until = float(a[a.index("--until") + 1].lstrip("@"))
    for t, msg in fx["kernel"]:
        if since <= t <= until:
            print(json.dumps({"MESSAGE": msg}))
''').lstrip()


class RestartCauses(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(); os.makedirs(f"{self.tmp}/bin")
        with open(f"{self.tmp}/bin/journalctl", "w") as f: f.write(FAKE)
        os.chmod(f"{self.tmp}/bin/journalctl", 0o755)
        self.t0 = int(time.time()) - 3600
        self.fixture = {"kernel": []}; self.vm = []

    def run_dir(self, name, *restarts, legacy=0):
        d = f"{self.tmp}/runs/{name}"; os.makedirs(d)
        for n in range(legacy):
            open(f"{d}/server_r{n + 1}.log", "w").close()
        if restarts:
            with open(f"{d}/restarts.log", "w") as f:
                for i, (turn, rc, start, at, pid, alive) in enumerate(restarts, 1):
                    f.write(f"restart={i} turn={turn} rc={rc} turn_start={start} at={at} server_pid={pid} server_alive={alive}\n")
        return d

    def sample(self, t, avail, swapfree, majflt=0):
        self.vm.append(f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t))} swapin=0 swapout=0 "
                       f"majflt={majflt} avail_mb={avail} swapfree_mb={swapfree}")

    def audit(self, *dirs):
        with open(f"{self.tmp}/j.json", "w") as f: json.dump(self.fixture, f)
        with open(f"{self.tmp}/vmstat.log", "w") as f: f.write("\n".join(self.vm) + "\n")
        env = {"PATH": f"{self.tmp}/bin:/usr/bin:/bin", "FAKE_JOURNAL": f"{self.tmp}/j.json", "HOME": self.tmp}
        r = subprocess.run([sys.executable, TOOL, *dirs, "--vmstat", f"{self.tmp}/vmstat.log"],
                           capture_output=True, text=True, env=env)
        return r.stdout + r.stderr

    def test_dead_server_with_a_kernel_kill_is_an_oom_kill(self):
        self.fixture["kernel"] = [[self.t0 + 100, "Out of memory: Killed process 4242 (llama-server) total-vm:1kB"]]
        out = self.audit(self.run_dir("r", (3, 0, self.t0, self.t0 + 120, 4242, "no")))
        self.assertIn("after turn 3: oom-kill", out)

    def test_a_kill_of_another_pid_does_not_count(self):
        self.fixture["kernel"] = [[self.t0 + 100, "Out of memory: Killed process 999 (llama-server) total-vm:1kB"]]
        out = self.audit(self.run_dir("r", (3, 0, self.t0, self.t0 + 120, 4242, "no")))
        self.assertIn("died, no kill record", out)

    def test_unreadable_kernel_log_is_not_no_kill(self):
        self.fixture["fail"] = True
        out = self.audit(self.run_dir("r", (3, 0, self.t0, self.t0 + 120, 4242, "no")))
        self.assertIn("died, kill log unreadable", out); self.assertNotIn("no kill record", out)

    def test_timeout_while_swap_ran_out_says_so(self):   # J2, NeoHorse Q8 r2 turn 4
        for k, (avail, sw) in enumerate([(256, 564), (95, 326), (16, 0), (29, 0)]):
            self.sample(self.t0 + 60 * k, avail, sw, majflt=300_000 if sw == 0 else 2000)
        out = self.audit(self.run_dir("r", (4, 124, self.t0, self.t0 + 691, 4242, "yes")))
        self.assertIn("after turn 4: timeout, swap exhausted", out); self.assertIn("min avail 16MB", out)

    def test_timeout_without_memory_pressure(self):      # J2, gemma turn 6
        for k in range(30):
            self.sample(self.t0 + 60 * k, 800, 1844)
        out = self.audit(self.run_dir("r", (6, 124, self.t0, self.t0 + 1800, 4242, "yes")))
        self.assertIn("after turn 6: timeout, no memory pressure", out)

    def test_samples_outside_the_turn_are_ignored(self):
        self.sample(self.t0 - 600, 16, 0)                 # before the turn
        self.sample(self.t0 + 60, 800, 1844)
        out = self.audit(self.run_dir("r", (2, 124, self.t0, self.t0 + 120, 4242, "yes")))
        self.assertIn("timeout, no memory pressure", out)

    def test_timeout_without_samples(self):
        out = self.audit(self.run_dir("r", (6, 124, self.t0, self.t0 + 1800, 4242, "yes")))
        self.assertIn("timeout, no memory samples", out)

    def test_alive_but_unhealthy(self):
        out = self.audit(self.run_dir("r", (5, 1, self.t0, self.t0 + 60, 4242, "yes")))
        self.assertIn("after turn 5: unhealthy", out)

    def test_run_before_restarts_log_is_unrecorded_not_clean(self):
        out = self.audit(self.run_dir("old", legacy=2))
        self.assertIn("2 restart(s) NOT RECORDED", out)


if __name__ == "__main__":
    unittest.main()
