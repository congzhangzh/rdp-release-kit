#!/usr/bin/env python3
# Compares the usage strings of a built Mac bundle (or the client archive's README) with the
# committed expected file, byte for byte:
#
#   check-bundle-strings.py <expected-strings.txt> host   <FreeRDP-Shadow.app>
#   check-bundle-strings.py <expected-strings.txt> client <FreeRDP.app>
#   check-bundle-strings.py <expected-strings.txt> readme <README.txt>
#   check-bundle-strings.py <expected-strings.txt> kit-readme <kit dir>
#
# The expected file (test/probe-camera-mac/expected-strings.txt, made by make-strings.py from
# the product owner's words) has one line per string: <what>\t<key>\t<lang>\t<text>. For a
# bundle, en is Contents/Info.plist's value, every other language
# Contents/Resources/<lang>.lproj/InfoPlist.strings (UTF-8); CFBundleLocalizations must list
# them all. For the README, each text must be one whole line of it; for the kit's READMEs
# (kit-readme: <key> is the file), each text must be in that file. Runs anywhere (python3,
# no macOS tool); exit 1 on the first difference's report, after checking everything.
import plistlib
import re
import sys
from pathlib import Path

STRINGS_LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def unescape(s):
    return re.sub(r"\\(.)", r"\1", s)


def read_strings(path):
    """our InfoPlist.strings form: comments, then "key" = "value"; lines (UTF-8)"""
    out = {}
    text = path.read_bytes().decode("utf-8")  # raises on anything that is not UTF-8
    for line in text.splitlines():
        m = STRINGS_LINE.match(line)
        if m:
            out[unescape(m.group(1))] = unescape(m.group(2))
    return out


def hexdump(s):
    return s.encode("utf-8").hex(" ")


def main():
    if len(sys.argv) != 4 or sys.argv[2] not in ("host", "client", "readme", "kit-readme"):
        sys.exit("usage: check-bundle-strings.py <expected-strings.txt> host|client|readme|kit-readme "
                 "<bundle, README or kit dir>")
    expected, what, target = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    rows = []
    for raw in expected.read_bytes().decode("utf-8").splitlines():
        if raw:
            w, key, lang, text = raw.split("\t", 3)
            if w == what:
                rows.append((key, lang, text))
    if not rows:
        sys.exit(f"{expected}: nothing for {what}")

    bad = 0

    def same(label, got, want):
        nonlocal bad
        if got == want:
            print(f"ok    {label}: {got}")
        else:
            bad = 1
            print(f"FAIL  {label}:\n        got  {got!r}\n             [{hexdump(got) if got else ''}]\n"
                  f"        want {want!r}\n             [{hexdump(want)}]")

    if what == "kit-readme":
        for key, lang, text in rows:
            body = (target / key).read_bytes().decode("utf-8")
            same(f"{key} ({lang})", text if text in body else "(not in the file)", text)
        return bad

    if what == "readme":
        lines = target.read_bytes().decode("utf-8").splitlines()
        for key, lang, text in rows:
            same(f"README {lang}", text if text in lines else "(no such line)", text)
        return bad

    info = plistlib.loads((target / "Contents/Info.plist").read_bytes())
    langs = sorted({lang for _, lang, _ in rows})
    have = info.get("CFBundleLocalizations") or []
    same("CFBundleLocalizations", ",".join(sorted(have)), ",".join(langs))
    for key, lang, text in rows:
        if lang == "en":
            same(f"Info.plist {key}", info.get(key, ""), text)
            continue
        path = target / f"Contents/Resources/{lang}.lproj/InfoPlist.strings"
        try:
            got = read_strings(path).get(key, "") if path.is_file() else "(no file)"
        except UnicodeDecodeError:
            got = "(not UTF-8)"
        same(f"{lang}.lproj {key}", got, text)
    return bad


if __name__ == "__main__":
    sys.exit(main())
