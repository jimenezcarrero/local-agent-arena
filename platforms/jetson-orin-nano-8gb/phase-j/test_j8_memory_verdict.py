"""Tests for j8_memory_verdict.py on synthetic evidence (no model run needed)."""
import datetime, importlib.util, os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("v", os.path.join(HERE, "j8_memory_verdict.py"))
v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)

T0 = datetime.datetime(2026, 10, 4, 1, 0, 0).astimezone()
RUN, M3, M8 = v.RUN, v.MODEL, "granite-4.2-8b-IQ3_XXS.gguf"


def iso(sec):
    return (T0 + datetime.timedelta(seconds=sec)).isoformat(timespec="seconds")


def results(total=3600):
    return f"{iso(total)} RESULT {RUN}: arena=4 pimodel=local32k pytest=PASS total={total}s\n"


def rss(points, model=M3, pid=111):
    return [f"{iso(t)} pid={pid} model={model} vmhwm_kb={h} rss_anon_kb={a}" for t, h, a in points]


def steady(hwm=5_000_000, total=3600, step=30):
    return [(t, hwm, 4_700_000) for t in range(0, total + 1, step)]


OOM0 = f"{RUN}  oom_kills=0  start=x\n"


class Verdict(unittest.TestCase):
    def check(self, lines, oom, res, want):
        got, why, _ = v.verdict(lines, oom, res)
        self.assertEqual(got, want, why)

    def test_low_peak_full_coverage_supports(self):
        self.check(rss(steady()), OOM0, results(), "supports")

    def test_spike_between_rss_samples_is_caught_by_vmhwm(self):
        pts = steady()
        # RssAnon never shows the spike (it came and went between samples), but
        # the kernel's high-water mark keeps it from the next sample on
        pts = [(t, 6_600_000 if t >= 1800 else h, a) for t, h, a in pts]
        self.check(rss(pts), OOM0, results(), "refutes")

    def test_missing_values_are_discarded_and_gaps_count(self):
        lines = rss(steady())
        lines[40] = f"{iso(1200)} pid=111 model={M3} vmhwm_kb= rss_anon_kb="     # process exited mid-read
        self.check(lines, OOM0, results(), "supports")                           # one dropped sample: 60s gap
        lines = [l for i, l in enumerate(rss(steady())) if not 40 <= i <= 45]    # ~180s without samples
        self.check(lines, OOM0, results(), "inconclusive")

    def test_kill_refutes(self):
        self.check(rss(steady()), f"{RUN}  oom_kills=1  start=x\n", results(), "refutes")

    def test_missing_or_unknown_oom_row_is_inconclusive(self):
        self.check(rss(steady()), "", results(), "inconclusive")
        self.check(rss(steady()), f"{RUN}  oom_kills=unknown\n", results(), "inconclusive")

    def test_8b_samples_never_count(self):
        lines = rss(steady()) + rss(steady(hwm=7_000_000), model=M8, pid=222)
        self.check(lines, OOM0, results(), "supports")

    def test_samples_must_cover_the_run(self):
        self.check(rss([p for p in steady() if p[0] >= 600]), OOM0, results(), "inconclusive")

    def test_too_few_samples(self):
        self.check(rss(steady(step=600)), OOM0, results(), "inconclusive")

    def test_between_thresholds_is_inconclusive(self):
        self.check(rss(steady(hwm=6_000_000)), OOM0, results(), "inconclusive")

    def test_no_result_line(self):
        self.check(rss(steady()), OOM0, "", "inconclusive")

    def test_restart_across_two_pids_uses_the_max(self):
        a = [(t, 5_000_000, 4_700_000) for t in range(0, 1801, 30)]
        b = [(t, 6_700_000, 4_700_000) for t in range(1830, 3601, 30)]
        self.check(rss(a, pid=111) + rss(b, pid=333), OOM0, results(), "refutes")


if __name__ == "__main__":
    unittest.main()
