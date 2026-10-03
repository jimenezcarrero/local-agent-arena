"""Tests for pi_smoke.py with a fake pi on PATH (no model, no real pi)."""
import os, subprocess, sys, tempfile, textwrap, unittest

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pi_smoke.py")
FAKE_PI = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import json, os, sys
    a = sys.argv[1:]; sd = a[a.index("--session-dir") + 1]; os.makedirs(sd, exist_ok=True)
    def call(i, name, args): return {"type": "message", "message": {"role": "assistant", "content": [{"type": "toolCall", "id": f"c{i}", "name": name, "arguments": args}]}}
    def res(i, name, err): return {"type": "message", "message": {"role": "toolResult", "toolCallId": f"c{i}", "toolName": name, "isError": err, "content": []}}
    ev = [{"type": "message", "message": {"role": "user", "content": "task"}}]
    if os.environ["FAKE"] == "good":
        steps = [("read", {"path": "missing.txt"}, True), ("read", {"path": "notes.txt"}, False),
                 ("edit", {"path": "notes.txt", "edits": []}, False), ("bash", {"command": "wc -w notes.txt > count.txt"}, False)]
    else:  # files made by write: must not satisfy the call checks
        steps = [("read", {"path": "missing.txt"}, True), ("write", {"path": "notes.txt"}, False), ("write", {"path": "count.txt"}, False)]
    for i, (n, ar, er) in enumerate(steps):
        ev += [call(i, n, ar), res(i, n, er)]
    open("notes.txt", "w").write("omega beta gamma\n"); open("count.txt", "w").write("3 notes.txt\n")
    with open(os.path.join(sd, "s.jsonl"), "w") as f:
        f.write("\n".join(json.dumps(e) for e in ev) + "\n")
''').lstrip()


class Smoke(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(); os.makedirs(f"{self.tmp}/bin"); os.makedirs(f"{self.tmp}/home")
        with open(f"{self.tmp}/bin/pi", "w") as f: f.write(FAKE_PI)
        os.chmod(f"{self.tmp}/bin/pi", 0o755)
        self.bench = f"{self.tmp}/bench"

    def run_smoke(self, label, fake="good", bench=None, home=None):
        env = {"PATH": f"{self.tmp}/bin:/usr/bin:/bin", "BENCH_WORK": bench or self.bench,
               "HOME": home or f"{self.tmp}/home", "FAKE": fake}
        r = subprocess.run([sys.executable, TOOL, label, f"{self.tmp}/ev.txt"], capture_output=True, text=True, env=env)
        return r.returncode, r.stdout + r.stderr

    def test_full_sequence_passes(self):
        rc, out = self.run_smoke("ok"); self.assertEqual(rc, 0, out); self.assertIn("pi smoke PASS", out)

    def test_files_made_by_write_fail_the_call_checks(self):
        rc, out = self.run_smoke("w", fake="write"); self.assertEqual(rc, 1, out)
        self.assertIn("FAIL  call: edit notes.txt succeeds", out); self.assertIn("PASS  file: count.txt", out)

    def test_absolute_label_is_refused_and_nothing_is_touched(self):
        outside = f"{self.tmp}/outside"; os.makedirs(outside); open(f"{outside}/keep", "w").close()
        rc, out = self.run_smoke(outside); self.assertEqual(rc, 2); self.assertTrue(os.path.exists(f"{outside}/keep"))

    def test_traversal_label_is_refused(self):
        rc, out = self.run_smoke(".."); self.assertEqual(rc, 2)
        rc, out = self.run_smoke("../x"); self.assertEqual(rc, 2)

    def test_repeated_label_is_refused_and_keeps_evidence(self):
        self.assertEqual(self.run_smoke("same")[0], 0)
        rc, out = self.run_smoke("same"); self.assertEqual(rc, 2); self.assertIn("already exists", out)
        self.assertTrue(os.path.exists(f"{self.bench}/pi-smoke/same/pi.log"))

    def test_ancestor_context_file_is_refused(self):
        open(f"{self.tmp}/CLAUDE.md", "w").close()
        rc, out = self.run_smoke("c"); self.assertEqual(rc, 2); self.assertIn("ancestor context file", out)
        self.assertFalse(os.path.exists(f"{self.bench}/pi-smoke/c"))

    def test_global_agent_context_is_refused(self):
        os.makedirs(f"{self.tmp}/home/.pi/agent"); open(f"{self.tmp}/home/.pi/agent/AGENTS.md", "w").close()
        rc, out = self.run_smoke("g"); self.assertEqual(rc, 2); self.assertIn("injected", out)


if __name__ == "__main__":
    unittest.main()
