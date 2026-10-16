#!/usr/bin/env python3
"""pkg_identity.py (D176): the release package's identity, as built.

  pkg_identity.py check <manifest> <package dir>
      PASS only if the package is exactly the manifest: every "file" entry a regular file (not a symlink) with its
      sha256; every "link" entry a symlink whose target text is the one recorded, resolving (relative: inside the
      package, to a "file" entry; absolute: to an "ext" entry); every "ext" file (outside the package) with its
      sha256; and nothing else in the package (an extra library on LD_LIBRARY_PATH could shadow a pinned one).
      Prints one line per mismatch and a final "RESULT pkg-identity: PASS|FAIL (...)" line; exit 0 only on PASS.
  pkg_identity.py make <build record .sha256> <package dir>
      Writes a manifest to stdout: the files and hashes of the build record (sha256sum lines "<hash>  ./<path>"),
      refusing if any installed file differs from it or is missing; the package's symlinks with their target text;
      for an absolute link target, its current sha256 as an "ext" entry. Run once, by hand, when a manifest is
      declared; the driver only checks (expectations are never regenerated at launch).

Manifest lines: "file <relative path> <sha256>", "link <relative path> <target text>", "ext <absolute path> <sha256>";
"#" starts a comment."""
import hashlib, os, sys


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def walk(root):
    """every non-directory entry under root, as relative paths (symlinks not followed)"""
    out = set()
    for d, dirs, files in os.walk(root):
        for n in files + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
            out.add(os.path.relpath(os.path.join(d, n), root))
    return out


def load(manifest):
    files, links, ext = {}, {}, {}
    for n, line in enumerate(open(manifest), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        kind, path, val = line.split(None, 2)
        {"file": files, "link": links, "ext": ext}[kind][path] = val
    return files, links, ext


def check(manifest, root):
    files, links, ext = load(manifest)
    bad = []
    for rel, want in sorted(files.items()):
        p = os.path.join(root, rel)
        if os.path.islink(p):
            bad.append(f"{rel}: a symlink ({os.readlink(p)}), expected a regular file")
        elif not os.path.isfile(p):
            bad.append(f"{rel}: missing")
        elif sha(p) != want:
            bad.append(f"{rel}: sha256 differs from the manifest")
    for rel, target in sorted(links.items()):
        p = os.path.join(root, rel)
        if not os.path.islink(p):
            bad.append(f"{rel}: {'missing' if not os.path.exists(p) else 'not a symlink'}, expected a link to {target}")
            continue
        if os.readlink(p) != target:
            bad.append(f"{rel}: links to {os.readlink(p)}, expected {target}")
            continue
        final = os.path.realpath(p)
        if os.path.isabs(target):
            if final not in ext and target not in ext:
                bad.append(f"{rel}: resolves to {final}, not a pinned external file")
        else:
            inside = os.path.relpath(final, os.path.realpath(root))
            if inside.startswith("..") or inside not in files:
                bad.append(f"{rel}: resolves to {final}, not a pinned file of the package")
    for path, want in sorted(ext.items()):
        if not os.path.isfile(path):
            bad.append(f"{path}: missing (external)")
        elif sha(path) != want:
            bad.append(f"{path}: sha256 differs from the manifest (external)")
    extra = sorted(walk(root) - set(files) - set(links))
    for rel in extra:
        bad.append(f"{rel}: not in the manifest")
    for b in bad:
        print("FAIL " + b)
    print(f"RESULT pkg-identity: {'PASS' if not bad else 'FAIL'} ({len(files)} files, {len(links)} links, {len(ext)} "
          f"external; {len(bad)} mismatches)")
    return 0 if not bad else 1


def make(record, root):
    out, refuse = [], []
    for line in open(record):
        if not line.strip():
            continue
        h, path = line.split(None, 1)
        rel = os.path.normpath(path.strip())
        p = os.path.join(root, rel)
        if os.path.islink(p) or not os.path.isfile(p):
            refuse.append(f"{rel}: missing or not a regular file")
        elif sha(p) != h:
            refuse.append(f"{rel}: installed file differs from the build record")
        out.append(f"file {rel} {h}")
    rec = {os.path.normpath(l.split(None, 1)[1].strip()) for l in open(record) if l.strip()}
    for rel in sorted(walk(root)):
        p = os.path.join(root, rel)
        if os.path.islink(p):
            t = os.readlink(p); out.append(f"link {rel} {t}")
            if os.path.isabs(t):
                out.append(f"ext {os.path.realpath(p)} {sha(os.path.realpath(p))}")
        elif rel not in rec:
            refuse.append(f"{rel}: installed but not in the build record")
    if refuse:
        sys.stderr.write("refused:\n" + "\n".join(refuse) + "\n"); return 1
    print("\n".join(out)); return 0


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("check", "make"):
        sys.exit(__doc__)
    sys.exit((check if sys.argv[1] == "check" else make)(sys.argv[2], sys.argv[3]))
