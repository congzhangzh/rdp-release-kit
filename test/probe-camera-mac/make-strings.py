#!/usr/bin/env python3
# Makes the Mac bundles' usage strings from their sources, byte for byte (never retyped):
#
#   make-strings.py [--check] <PO strings draft> <camera lane's kit patch> <PO README draft> <kit dir>
#
#   <PO strings draft>   rdp-product-plan/drafts/mac-signing-strings.v1.md, section 1:
#                        NSSystemExtensionUsageDescription of FreeRDP-Shadow.app, en/zh/ja/fr
#   <kit patch>          freerdp-comp-camera-g1's kit-camera.v2.patch: the client's
#                        NSCameraUsageDescription in its four InfoPlist.strings (the PO's words)
#   <PO README draft>    rdp-product-plan/drafts/readme-mac-camera.v1.md: the Mac client
#                        README's camera paragraph, en/zh/ja/fr
#
# Writes, in the kit:
#   build/macos/host-lproj/{zh-Hans,ja,fr}.lproj/InfoPlist.strings   (en is in host-Info.plist)
#   build/macos/client-lproj/{en,zh-Hans,ja,fr}.lproj/InfoPlist.strings
#   the en value in build/macos/host-Info.plist and build/macos/client-Info.plist
#   build/macos/client-README-camera.txt: the four README lines, appended to the client
#   archive's README.txt by build-macos-client.sh
#   test/probe-camera-mac/expected-strings.txt: what check-bundle-strings.py compares a built
#   bundle with, one line per string: <bundle>\t<key>\t<lang>\t<text>
# --check: changes nothing, fails if any of these differs from what it would write.
import re
import sys
from pathlib import Path

LANG = {"en": "en", "zh": "zh-Hans", "ja": "ja", "fr": "fr"}


def po_section1(path):
    text = Path(path).read_text(encoding="utf-8")
    m = re.search(r"^## 1\. NSSystemExtensionUsageDescription.*?\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not m:
        sys.exit(f"{path}: no section 1")
    out = {}
    for line in m.group(1).splitlines():
        lm = re.match(r"^- (en|zh|ja|fr): (.+)$", line)
        if lm:
            out[LANG[lm.group(1)]] = lm.group(2)
    if sorted(out) != sorted(LANG.values()):
        sys.exit(f"{path}: section 1 has {sorted(out)}, want en, zh, ja, fr")
    return out


def patch_camera(path):
    text = Path(path).read_text(encoding="utf-8")
    out = {}
    for m in re.finditer(r"^\+\+\+ b/build/macos/client-lproj/([A-Za-z-]+)\.lproj/InfoPlist\.strings\n"
                         r"(?:.*\n)*?\+\"NSCameraUsageDescription\" = \"(.*)\";$", text, re.M):
        out[m.group(1)] = m.group(2).replace('\\"', '"').replace("\\\\", "\\")
    if sorted(out) != sorted(LANG.values()):
        sys.exit(f"{path}: NSCameraUsageDescription for {sorted(out)}, want en, zh-Hans, ja, fr")
    return out


def po_readme(path):
    out = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        lm = re.match(r"^- (en|zh|ja|fr): (.+)$", line)
        if lm:
            out[LANG[lm.group(1)]] = lm.group(2)
    if sorted(out) != sorted(LANG.values()):
        sys.exit(f"{path}: README lines for {sorted(out)}, want en, zh, ja, fr")
    return out


def strings_file(bundle, key, lang, value):
    esc = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'/* {bundle}, {lang} (made by test/probe-camera-mac/make-strings.py) */\n"{key}" = "{esc}";\n'


def xml(value):
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def set_plist_line(text, key, value):
    line = f"    <key>{key}</key> <string>{xml(value)}</string>"
    pat = re.compile(rf"^    <key>{key}</key>.*$", re.M)
    if pat.search(text):
        return pat.sub(lambda _: line, text, count=1)
    return text.replace("</dict>\n</plist>", f"{line}\n</dict>\n</plist>", 1)


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv
    if len(args) != 4:
        sys.exit("usage: make-strings.py [--check] <PO strings draft> <kit patch> <PO README draft> <kit dir>")
    host = po_section1(args[0])
    client = patch_camera(args[1])
    readme = po_readme(args[2])
    kit = Path(args[3])
    files = {}
    for lang in ("zh-Hans", "ja", "fr"):
        files[kit / f"build/macos/host-lproj/{lang}.lproj/InfoPlist.strings"] = strings_file(
            "FreeRDP-Shadow.app", "NSSystemExtensionUsageDescription", lang, host[lang])
    for lang in ("en", "zh-Hans", "ja", "fr"):
        files[kit / f"build/macos/client-lproj/{lang}.lproj/InfoPlist.strings"] = strings_file(
            "FreeRDP.app", "NSCameraUsageDescription", lang, client[lang])
    for name, key, value in (("host-Info.plist", "NSSystemExtensionUsageDescription", host["en"]),
                             ("client-Info.plist", "NSCameraUsageDescription", client["en"])):
        p = kit / "build/macos" / name
        files[p] = set_plist_line(p.read_text(encoding="utf-8"), key, value)
    order = ("en", "zh-Hans", "ja", "fr")
    files[kit / "build/macos/client-README-camera.txt"] = "".join(readme[lang] + "\n" for lang in order)
    lines = [f"host\tNSSystemExtensionUsageDescription\t{lang}\t{host[lang]}" for lang in ("en", "zh-Hans", "ja", "fr")]
    lines += [f"client\tNSCameraUsageDescription\t{lang}\t{client[lang]}" for lang in ("en", "zh-Hans", "ja", "fr")]
    lines += [f"readme\tcamera\t{lang}\t{readme[lang]}" for lang in order]
    files[kit / "test/probe-camera-mac/expected-strings.txt"] = "\n".join(lines) + "\n"
    bad = 0
    for path, content in files.items():
        old = path.read_text(encoding="utf-8") if path.exists() else None
        if old == content:
            continue
        if check:
            print(f"differs: {path}")
            bad = 1
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8", newline="\n")
            print(f"wrote {path}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
