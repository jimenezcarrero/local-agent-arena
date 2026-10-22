# Filter a git fast-export stream: replace each target MAC (TARGETS file, one per line, lower case with ':') with <mac>
# in every blob and commit message, in either case and with ':' or '-' as the separator, and fix each "data <n>"
# length. Every data record must be complete: a short read, a delimited ("data <<") record or a malformed length
# aborts with exit 1 and nothing is passed on for it. Prints counts to stderr, never the values.
import os, re, sys

targets = [l.strip() for l in open(os.environ["TARGETS"]) if l.strip()]
if not targets or not all(re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", t) for t in targets):
    sys.exit("mac_filter: TARGETS must hold MAC addresses, lower case with ':'")


def pattern(i, t):
    """One target, either separator used throughout (named group s<i>), any case."""
    pairs = t.split(":")
    return (f"(?:{pairs[0]}(?P<s{i}>[:-])" + "".join(f"{p}(?P=s{i})" for p in pairs[1:-1]) + pairs[-1] + ")")


RX = re.compile("|".join(pattern(i, t) for i, t in enumerate(targets)).encode(), re.I)
inp, out = sys.stdin.buffer, sys.stdout.buffer
n = records = 0
while True:
    line = inp.readline()
    if not line:
        break
    if line.startswith(b"data "):
        arg = line[5:].rstrip(b"\n")
        if not arg.isdigit():
            sys.exit("mac_filter: unsupported or malformed data record (not an exact length)")
        size = int(arg); data = inp.read(size)
        if len(data) != size:
            sys.exit(f"mac_filter: truncated data record ({len(data)} of {size} bytes)")
        data, c = RX.subn(b"<mac>", data)
        n += c; records += 1
        out.write(b"data %d\n" % len(data)); out.write(data)
    else:
        out.write(line)
out.flush()
sys.stderr.write(f"mac_filter: {records} data records, {n} replacements\n")
