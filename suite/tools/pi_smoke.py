#!/usr/bin/env python3
"""pi_smoke.py <label> <evidence.txt> — a short real-pi session against the running server.

The tool probes talk to the server directly; this drives pi itself (streaming,
its own parser and tool loop) through one small task:
  1. read missing.txt, which doesn't exist (a deliberate tool error);
  2. read notes.txt;
  3. change the word alpha to omega in notes.txt;
  4. run `wc -w notes.txt > count.txt`.
Checks, all required: pi exits 0 within 600s; the session records a failed tool
result (isError) for missing.txt and at least three tool calls; notes.txt says
omega and no longer alpha; count.txt holds "3 notes.txt".

Environment: PI_PROVIDER (default bench) and PI_MODEL (default local), as the
suite uses them. The work directory goes under $BENCH_WORK/pi-smoke/<label>
(default ~/bench-runs), outside any repository. Exit 0 only if every check passed.
"""
import glob, json, os, re, shutil, subprocess, sys

PROMPT = ("Do these steps with your tools, in order. 1) Read the file missing.txt; it does not exist, "
          "so note the error and continue. 2) Read notes.txt. 3) Change the word alpha to omega in notes.txt. "
          "4) Run the shell command: wc -w notes.txt > count.txt. Then reply with the single word DONE.")


def main(argv):
    if len(argv) != 2:
        raise SystemExit(__doc__)
    label, out = argv
    root = os.path.join(os.environ.get("BENCH_WORK", os.path.expanduser("~/bench-runs")), "pi-smoke", label)
    shutil.rmtree(root, ignore_errors=True)
    work = os.path.join(root, "work"); os.makedirs(work)
    with open(os.path.join(work, "notes.txt"), "w") as f:
        f.write("alpha beta gamma\n")
    provider = os.environ.get("PI_PROVIDER", "bench"); model = os.environ.get("PI_MODEL", "local")
    cmd = ["timeout", "600", "pi", "--provider", provider, "--model", model,
           "--session-dir", os.path.join(root, "pisessions"), "-p", PROMPT]
    rc = subprocess.run(cmd, cwd=work, stdout=open(os.path.join(root, "pi.log"), "w"),
                        stderr=subprocess.STDOUT).returncode
    calls = errs_missing = 0
    for s in glob.glob(os.path.join(root, "pisessions", "*.jsonl")):
        for line in open(s, errors="replace"):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            m = e.get("message") if isinstance(e.get("message"), dict) else None
            if not m:
                continue
            if m.get("role") == "assistant" and isinstance(m.get("content"), list):
                calls += sum(1 for x in m["content"] if isinstance(x, dict) and x.get("type") == "toolCall")
            if m.get("role") == "toolResult" and m.get("isError") and "missing.txt" in json.dumps(m):
                errs_missing += 1
    notes = open(os.path.join(work, "notes.txt")).read()
    count_path = os.path.join(work, "count.txt")
    count = open(count_path).read().strip() if os.path.exists(count_path) else ""
    checks = [("pi exited 0", rc == 0, f"rc={rc}"),
              ("tool error recorded for missing.txt", errs_missing > 0, f"{errs_missing} error result(s)"),
              ("at least 3 tool calls", calls >= 3, f"{calls} call(s)"),
              ("notes.txt edited", "omega" in notes and "alpha" not in notes, repr(notes.strip())),
              ("command ran", re.fullmatch(r"3\s+notes\.txt", count) is not None, repr(count))]
    lines = [f"## {label} (pi smoke: provider={provider} model={model}, work={work})"]
    lines += [f"{'PASS' if ok else 'FAIL'}  {name}: {detail}" for name, ok, detail in checks]
    passed = all(ok for _, ok, _ in checks)
    lines.append(f"RESULT {label}: pi smoke {'PASS' if passed else 'FAIL'} "
                 f"({sum(ok for _, ok, _ in checks)}/{len(checks)} checks)")
    print("\n".join(lines))
    with open(out, "a") as f:
        f.write("\n".join(lines) + "\n\n")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
