#!/usr/bin/env python3
"""scan_identifiers.py [--hostname] [--boot-id] <path>... (D182) — check evidence for device identifiers before it is
committed. Reads every regular file under the paths, decompressing .gz and the members of .tar/.tar.gz archives.
Always checked: the machine-id, the SoC serial, unredacted USB serials ("SerialNumber: <value>") and MAC addresses
(publish_monitor.py's expression; <mac> is the redacted form). --hostname and --boot-id add the board's hostname and
current boot id (npu-dev evidence redacts them; phase-v0's monitor export keeps them).
Prints one line per file and kind with a count, never the value, then "RESULT scan: CLEAN (<n> files)" (exit 0) or
"RESULT scan: FOUND ..." (exit 1). Identifier sources are overridable for tests: SCAN_MACHINE_ID, SCAN_SERIAL,
SCAN_HOSTNAME, SCAN_BOOT_ID (values)."""
import gzip, io, os, re, socket, sys, tarfile

MAC = re.compile(rb"(?<![0-9A-Fa-f:-])[0-9A-Fa-f]{2}([:-])(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])")
USB_SERIAL = re.compile(rb"SerialNumber: (?!<usb-serial>)[^\s\"\\]+")


def _read(path):
    try:
        return open(path).read().strip()
    except OSError:
        return ""


args = sys.argv[1:]
opts = {a for a in args if a.startswith("--")}
paths = [a for a in args if not a.startswith("--")]
if not paths or opts - {"--hostname", "--boot-id"}:
    sys.exit(__doc__)
fixed = {"machine-id": os.environ.get("SCAN_MACHINE_ID", _read("/etc/machine-id")),
         "soc-serial": os.environ.get("SCAN_SERIAL", _read("/sys/devices/soc0/serial_number"))}
if "--hostname" in opts:
    fixed["hostname"] = os.environ.get("SCAN_HOSTNAME", socket.gethostname())
if "--boot-id" in opts:
    fixed["boot-id"] = os.environ.get("SCAN_BOOT_ID", _read("/proc/sys/kernel/random/boot_id"))
fixed = {k: v.encode() for k, v in fixed.items() if v}


def contents(path):
    """(name, bytes) for the file, or for each member of an archive."""
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    try:
        with tarfile.open(fileobj=io.BytesIO(raw)) as t:
            members = [m for m in t.getmembers() if m.isfile()]
            for m in members:
                data = t.extractfile(m).read()
                if data[:2] == b"\x1f\x8b":
                    data = gzip.decompress(data)
                yield f"{path}:{m.name}", data
            return
    except tarfile.TarError:
        pass
    yield path, raw


files, found = 0, []
for p in paths:
    walk = [p] if os.path.isfile(p) else sorted(os.path.join(d, f) for d, _, fs in os.walk(p) for f in fs)
    for f in walk:
        if not os.path.isfile(f) or os.path.islink(f):
            continue
        files += 1
        for name, data in contents(f):
            hits = {k: data.count(v) for k, v in fixed.items()}
            hits["usb-serial"] = len(USB_SERIAL.findall(data))
            hits["mac"] = len(MAC.findall(data))
            for k, n in hits.items():
                if n:
                    found.append(k); print(f"{name}: {k} {n}")
if found:
    print(f"RESULT scan: FOUND {', '.join(sorted(set(found)))} ({files} files)"); sys.exit(1)
print(f"RESULT scan: CLEAN ({files} files)")
