#!/usr/bin/env python3
"""r2_mapped_peak.py (NPU dev plan R2): each NPU session's mapped-memory peak from a llama-server log taken with
GGML_HEXAGON_VERBOSE=1 at master af0579c78, against the R1 ledger's per-session figures.

  r2_mapped_peak.py <server log> <limit MiB per session, comma-separated, in session order> [--sessions HTP0:0,...]

ggml-hexagon.cpp logs, under the session that maps it, every buffer mapped into a session's address space ("ggml-hex:
<session> mapped buffer: base .. size <B> fd <fd> pinned <0|1> extended <0|1>", :745) and every unmapping
("ggml-hex: <session> unmapped buffer: base .. size <B> fd <fd>", :763); a clone of another session's buffer is mapped
by the receiving session (clone_buffer :4710-4737) and so appears under it. Per session the running total of mapped
bytes is kept by fd (a second map of a mapped fd, or an unmap of an unmapped fd, is an inconsistency: exit 3), and its
peak reported in two parts: pinned (the op queue's shared buffer, which the ledger subtracts from the limit) and the
rest (own buffers and clones, what the ledger counts). Fails closed (exit 3): unreadable log, no mapping line for a
listed session, a session in the log that is not listed, an inconsistent map/unmap, a malformed line.
Verdict: WITHIN (exit 0) only if every session's non-pinned peak <= its limit and its total peak <= 3,200 MiB
(HTP_OP_MAX_VMEM_DEFAULT); otherwise OVER (exit 1) with the sessions named."""
import argparse, re, sys

VMEM = 3355443200
MAP = re.compile(r"ggml-hex: (\S+) mapped buffer: base \S+ size (\d+) fd (-?\d+) pinned ([01]) extended ([01])\s*$")
UNMAP = re.compile(r"ggml-hex: (\S+) unmapped buffer: base \S+ size (\d+) fd (-?\d+)\s*$")
MiB = 1024 * 1024


def bad(msg):
    print(f"RESULT INVALID INPUT: {msg}"); sys.exit(3)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("log"); ap.add_argument("limits")
    ap.add_argument("--sessions", default="HTP0:0,HTP0:1,HTP0:2,HTP0:3")
    a = ap.parse_args()
    sessions = a.sessions.split(",");
    try:
        limits = [float(x) for x in a.limits.split(",")]
    except ValueError:
        bad("limits are not numbers")
    if len(limits) != len(sessions):
        bad(f"{len(limits)} limits for {len(sessions)} sessions")
    st = {s: {"open": {}, "cur": 0, "cur_pin": 0, "peak": 0, "peak_pin": 0, "peak_total": 0, "n": 0} for s in sessions}
    try:
        lines = open(a.log, errors="replace").read().splitlines()
    except OSError as e:
        bad(f"cannot read {a.log}: {e}")
    for i, l in enumerate(lines, 1):
        if "mapped buffer:" not in l:
            continue
        m, u = MAP.search(l), UNMAP.search(l)
        if not m and not u:
            bad(f"line {i}: malformed mapping line")
        s = (m or u).group(1)
        if s not in st:
            bad(f"line {i}: session {s} not in --sessions")
        x = st[s]; x["n"] += 1
        if m:
            size, fd, pin = int(m.group(2)), m.group(3), m.group(4) == "1"
            if fd in x["open"]:
                bad(f"line {i}: {s} maps fd {fd} twice")
            x["open"][fd] = (size, pin)
            if pin: x["cur_pin"] += size
            else: x["cur"] += size
        else:
            size, fd = int(u.group(2)), u.group(3)
            if fd not in x["open"] or x["open"][fd][0] != size:
                bad(f"line {i}: {s} unmaps fd {fd} that is not mapped with that size")
            _, pin = x["open"].pop(fd)
            if pin: x["cur_pin"] -= size
            else: x["cur"] -= size
        x["peak"] = max(x["peak"], x["cur"]); x["peak_pin"] = max(x["peak_pin"], x["cur_pin"])
        x["peak_total"] = max(x["peak_total"], x["cur"] + x["cur_pin"])
    over = []
    for s, lim in zip(sessions, limits):
        x = st[s]
        if x["n"] == 0:
            bad(f"no mapping line for session {s} (was GGML_HEXAGON_VERBOSE=1 set?)")
        ok = x["peak"] / MiB <= lim and x["peak_total"] <= VMEM
        if not ok: over.append(s)
        print(f"{s}: peak {x['peak'] / MiB:.1f} MiB own+clones (limit {lim:.1f}), pinned {x['peak_pin'] / MiB:.1f} MiB, "
              f"total {x['peak_total'] / MiB:.1f} MiB of {VMEM / MiB:.0f}, {x['n']} mapping lines: {'within' if ok else 'OVER'}")
    print("RESULT " + ("WITHIN" if not over else "OVER: " + ", ".join(over)))
    return 0 if not over else 1


if __name__ == "__main__":
    sys.exit(main())
