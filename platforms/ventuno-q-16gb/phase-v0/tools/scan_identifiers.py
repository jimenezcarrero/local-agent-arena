#!/usr/bin/env python3
"""scan_identifiers.py [--hostname] [--boot-id] <path>... (D182) — check evidence for device identifiers before it is
committed. Reads every regular file under the paths, unwrapping gzip and tar recursively (a .tar.gz inside a
.tar.gz, a .gz inside a .gz, up to DEPTH layers); any other container (zip, xz, bzip2, zstd) or a deeper nesting is an
error, never scanned as plain bytes.
Always checked: the machine-id, the SoC serial, unredacted USB serials ("SerialNumber: <value>") and MAC addresses
(publish_monitor.py's expression; <mac> is the redacted form). --hostname and --boot-id add the board's hostname and
current boot id (npu-dev evidence redacts them; phase-v0's monitor export keeps them).
Prints one line per file and kind with a count, never the value, then "RESULT scan: CLEAN (<n> files)" (exit 0),
"RESULT scan: FOUND ..." (exit 1), or "RESULT scan: ERROR ..." (exit 2: a requested path missing, a file or directory
unreadable, an unsupported or too deeply nested container; reported before any CLEAN could be). Identifier sources
are overridable for tests: SCAN_MACHINE_ID, SCAN_SERIAL, SCAN_HOSTNAME, SCAN_BOOT_ID (values)."""
import gzip, io, os, re, socket, sys, tarfile

MAC = re.compile(rb"(?<![0-9A-Za-z])[0-9A-Fa-f]{2}([:-])(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}(?![0-9A-Za-z])")
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


DEPTH = 8  # container layers (each gzip and each tar counts one): a .tar.gz in a .tar.gz with a .gz member is 5
OTHER = {b"PK\x03\x04": "zip", b"\xfd7zXZ\x00": "xz", b"BZh": "bzip2", b"\x28\xb5\x2f\xfd": "zstd"}


class ScanError(Exception):
    pass


def contents(name, data, depth=0):
    """(name, bytes) for each plain leaf inside data, unwrapping gzip and tar recursively."""
    if depth > DEPTH:
        raise ScanError(f"{name}: containers nested deeper than {DEPTH}")
    if data[:2] == b"\x1f\x8b":
        try:
            data = gzip.decompress(data)
        except (OSError, EOFError) as e:
            raise ScanError(f"{name}: unreadable gzip ({type(e).__name__})")
        yield from contents(name, data, depth + 1)
        return
    for magic, kind in OTHER.items():
        if data.startswith(magic):
            raise ScanError(f"{name}: unsupported container ({kind})")
    if len(data) >= 512 and data[257:262] == b"ustar":
        try:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as t:
                for m in t.getmembers():
                    if m.isfile():
                        yield from contents(f"{name}:{m.name}", t.extractfile(m).read(), depth + 1)
        except tarfile.TarError as e:
            raise ScanError(f"{name}: unreadable tar ({type(e).__name__})")
        return
    yield name, data


files, found, errors = 0, [], []


def walk_error(e):
    errors.append(f"{e.filename}: unreadable directory")


for p in paths:
    if not os.path.exists(p):
        errors.append(f"{p}: no such path"); continue
    walk = [p] if os.path.isfile(p) else sorted(os.path.join(d, f)
                                                for d, _, fs in os.walk(p, onerror=walk_error) for f in fs)
    for f in walk:
        if not os.path.isfile(f) or os.path.islink(f):
            continue
        files += 1
        try:
            raw = open(f, "rb").read()
            leaves = list(contents(f, raw))
        except OSError:
            errors.append(f"{f}: unreadable file"); continue
        except ScanError as e:
            errors.append(str(e)); continue
        for name, data in leaves:
            hits = {k: data.count(v) for k, v in fixed.items()}
            hits["usb-serial"] = len(USB_SERIAL.findall(data))
            hits["mac"] = len(MAC.findall(data))
            for k, n in hits.items():
                if n:
                    found.append(k); print(f"{name}: {k} {n}")
for e in errors:
    print(f"ERROR {e}")
if errors:
    print(f"RESULT scan: ERROR {len(errors)} input(s) not inspected ({files} files)"); sys.exit(2)
if found:
    print(f"RESULT scan: FOUND {', '.join(sorted(set(found)))} ({files} files)"); sys.exit(1)
print(f"RESULT scan: CLEAN ({files} files)")
