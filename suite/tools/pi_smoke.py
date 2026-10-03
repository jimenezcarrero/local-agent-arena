#!/usr/bin/env python3
"""pi_smoke.py <label> <evidence.txt> — a short real-pi session against the running server.

The tool probes talk to the server directly; this drives pi itself (streaming,
its own parser and tool loop) through one small task, naming pi's tools:
  1. the read tool on missing.txt, which doesn't exist (a deliberate tool error);
  2. the read tool on notes.txt;
  3. the edit tool, changing alpha to omega in notes.txt;
  4. the bash tool, running `wc -w notes.txt > count.txt`.
Checks, all required: pi exits 0 within 600s; those four calls appear in that
order, each matched to its own result by call id, the first failing (isError)
and the other three succeeding; and, as further evidence, notes.txt says omega
and no longer alpha, and count.txt holds "3 notes.txt". Files made some other
way (say, by the write tool) don't satisfy the call checks.

Safety: the label may contain only letters, digits, '.', '_' and '-'. The run
directory is $BENCH_WORK/pi-smoke/<label> (default ~/bench-runs), resolved and
confined there; an existing one is refused, never deleted, so earlier evidence
stays. Like suite/lib.sh, it refuses to run if an AGENTS.md or CLAUDE.md sits in
any ancestor of that directory or in ~/.pi/agent, because pi would feed it to
the model. All checks happen before anything is created.

Environment: PI_PROVIDER (default bench) and PI_MODEL (default local). Exit 0
only if every check passed; 2 if the run was refused.
"""
import glob, json, os, re, subprocess, sys

PROMPT = ("Do these steps in order, each with the tool named. 1) Use the read tool on missing.txt; it does "
          "not exist, so note the error and continue. 2) Use the read tool on notes.txt. 3) Use the edit tool "
          "to change the word alpha to omega in notes.txt. 4) Use the bash tool to run: wc -w notes.txt > count.txt. "
          "Then reply with the single word DONE.")
CONTEXT_FILES = ("AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD")


def refuse(out, label, why):
    line = f"## {label} (pi smoke)\nREFUSED: {why}\nRESULT {label}: pi smoke REFUSED\n"
    print(line, end="")
    with open(out, "a") as f:
        f.write(line + "\n")
    return 2


def preflight(label):
    """(run directory, None) or (None, reason); nothing is created here."""
    if not re.fullmatch(r"[A-Za-z0-9._-]+", label) or label in (".", ".."):
        return None, f"label {label!r} must be letters, digits, '.', '_' or '-'"
    base = os.path.realpath(os.path.join(os.environ.get("BENCH_WORK", os.path.expanduser("~/bench-runs")), "pi-smoke"))
    root = os.path.realpath(os.path.join(base, label))
    if os.path.dirname(root) != base:
        return None, f"run directory {root} is not inside {base}"
    if os.path.exists(root):
        return None, f"{root} already exists; use a new label (earlier evidence is kept)"
    for f in CONTEXT_FILES:
        g = os.path.join(os.path.expanduser("~/.pi/agent"), f)
        if os.path.exists(g):
            return None, f"{g} would be injected into the model under test"
    d = base
    while True:
        for f in CONTEXT_FILES:
            if os.path.exists(os.path.join(d, f)):
                return None, f"{os.path.join(d, f)} is an ancestor context file; pi would feed it to the model"
        if d == os.path.dirname(d):
            break
        d = os.path.dirname(d)
    return root, None


def tool_sequence(root):
    """[(name, arguments, is_error)] in call order, results matched by call id."""
    calls, results = [], {}
    for s in sorted(glob.glob(os.path.join(root, "pisessions", "*.jsonl"))):
        for line in open(s, errors="replace"):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            m = e.get("message") if isinstance(e.get("message"), dict) else None
            if not m:
                continue
            if m.get("role") == "assistant" and isinstance(m.get("content"), list):
                calls += [x for x in m["content"] if isinstance(x, dict) and x.get("type") == "toolCall"]
            elif m.get("role") == "toolResult":
                results[m.get("toolCallId")] = bool(m.get("isError"))
    return [(c.get("name"), c.get("arguments") or {}, results.get(c.get("id"))) for c in calls]


STEPS = [  # (description, predicate on (name, args), expected is_error)
    ("read missing.txt fails", lambda n, a: n == "read" and str(a.get("path", "")).endswith("missing.txt"), True),
    ("read notes.txt succeeds", lambda n, a: n == "read" and str(a.get("path", "")).endswith("notes.txt"), False),
    ("edit notes.txt succeeds", lambda n, a: n == "edit" and str(a.get("path", "")).endswith("notes.txt"), False),
    ("bash wc succeeds", lambda n, a: n == "bash" and "wc" in str(a.get("command", "")) and "count.txt" in str(a.get("command", "")), False),
]


def ordered_steps(seq):
    """[(description, found)] where each step must come after the previous one."""
    out, i = [], 0
    for desc, pred, err in STEPS:
        while i < len(seq) and not (pred(seq[i][0], seq[i][1]) and seq[i][2] is err):
            i += 1
        out.append((desc, i < len(seq)))
        i += 1 if i < len(seq) else 0
    return out


def main(argv):
    if len(argv) != 2:
        raise SystemExit(__doc__)
    label, out = argv
    root, why = preflight(label)
    if why:
        return refuse(out, label, why)
    work = os.path.join(root, "work"); os.makedirs(work)
    with open(os.path.join(work, "notes.txt"), "w") as f:
        f.write("alpha beta gamma\n")
    provider = os.environ.get("PI_PROVIDER", "bench"); model = os.environ.get("PI_MODEL", "local")
    cmd = ["timeout", "600", "pi", "--provider", provider, "--model", model,
           "--session-dir", os.path.join(root, "pisessions"), "-p", PROMPT]
    with open(os.path.join(root, "pi.log"), "w") as log:
        rc = subprocess.run(cmd, cwd=work, stdout=log, stderr=subprocess.STDOUT).returncode
    steps = ordered_steps(tool_sequence(root))
    notes = open(os.path.join(work, "notes.txt")).read()
    count_path = os.path.join(work, "count.txt")
    count = open(count_path).read().strip() if os.path.exists(count_path) else ""
    checks = [("pi exited 0", rc == 0, f"rc={rc}")]
    checks += [(f"call: {d}", ok, "in order" if ok else "not found in order") for d, ok in steps]
    checks += [("file: notes.txt edited", "omega" in notes and "alpha" not in notes, repr(notes.strip())),
               ("file: count.txt from the command", re.fullmatch(r"3\s+notes\.txt", count) is not None, repr(count))]
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
