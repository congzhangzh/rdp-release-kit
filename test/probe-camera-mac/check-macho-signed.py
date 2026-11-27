#!/usr/bin/env python3
# Every Mach-O in a directory (an unpacked archive as it is submitted to notarization) must be
# signed with a Developer ID of the team, with the hardened runtime and a secure timestamp:
#
#   check-macho-signed.py <dir> <team id>
#
# Mach-O by content (the magic of a thin or fat file), not by name. Per file: codesign -dv
# (inside a bundle it shows the bundle's signature for its main executable). Fails, listing
# them, on any file that is unsigned, ad hoc, of another team or authority, without
# flags=...(runtime), or without a timestamp. Prints a count per kind.
import subprocess
import sys
from pathlib import Path

THIN = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"}
FAT = {b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def is_macho(path):
    with open(path, "rb") as f:
        magic = f.read(4)
    if magic in THIN:
        return True
    if magic in FAT:  # also a Java class's magic: ask file
        r = subprocess.run(["file", "-b", str(path)], capture_output=True, encoding="utf-8", errors="replace")
        return r.stdout.startswith("Mach-O")
    return False


def problems(path, team):
    r = subprocess.run(["codesign", "-dv", "--verbose=4", str(path)],
                       capture_output=True, encoding="utf-8", errors="replace")
    text = r.stdout + r.stderr
    if r.returncode != 0:
        return [text.strip().splitlines()[-1] if text.strip() else "not signed"]
    out = []
    if "Signature=adhoc" in text:
        out.append("ad hoc")
    if f"TeamIdentifier={team}" not in text:
        out.append("team " + next((l.split("=", 1)[1] for l in text.splitlines() if l.startswith("TeamIdentifier=")), "none"))
    if "Authority=Developer ID Application:" not in text:
        out.append("no Developer ID Application authority")
    flags = next((l for l in text.splitlines() if "flags=" in l), "")
    if "(runtime)" not in flags and "runtime" not in flags:
        out.append("no hardened runtime (" + flags.strip() + ")")
    if "Timestamp=" not in text:
        out.append("no secure timestamp")
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: check-macho-signed.py <dir> <team id>")
    root, team = Path(sys.argv[1]), sys.argv[2]
    files = [p for p in sorted(root.rglob("*")) if p.is_file() and not p.is_symlink() and is_macho(p)]
    bad = 0
    for p in files:
        issues = problems(p, team)
        if issues:
            bad += 1
            print(f"FAIL  {p.relative_to(root)}: {'; '.join(issues)}")
    print(f"{'ok  ' if not bad else 'FAIL'}  {len(files) - bad} of {len(files)} Mach-O file(s) in {root.name}: "
          f"Developer ID ({team}), hardened runtime, timestamp")
    return 1 if bad or not files else 0


if __name__ == "__main__":
    sys.exit(main())
