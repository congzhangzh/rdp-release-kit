#!/usr/bin/env python3
# Makes FreeRDP.app's usage strings and the macOS client README's camera paragraph from the
# product owner's words, byte for byte (never retyped):
#
#   make-strings.py [--check] <PO usage descriptions> <PO README draft> <kit dir>
#
#   <PO usage descriptions>  rdp-product-plan/drafts/mac-usage-descriptions.v1.md: the client's
#                        NSCameraUsageDescription and NSMicrophoneUsageDescription, en/zh/ja/fr
#                        ("## <key>" sections of "- <lang>: <text>" lines)
#   <PO README draft>    rdp-product-plan/drafts/readme-mac-camera.v1.md: the macOS client
#                        README's camera paragraph, en/zh/ja/fr
#
# The README style rule (the RM, 2026-11-27): a README line takes its target README's style.
# The client's README.txt writes ASCII apostrophes in French, so U+2019 becomes "'" there (the
# Info.plist strings keep U+2019), and no space between Latin words and Japanese (a `code span`
# keeps its spaces). These are the only changes made to the drafts' bytes; the expected file
# holds the result.
#
# Writes, in the kit:
#   build/macos/client-lproj/{en,zh-Hans,ja,fr}.lproj/InfoPlist.strings
#   the en values in build/macos/client-Info.plist
#   build/macos/client-README-camera.txt: the four README lines, appended to the client
#   archive's README.txt by build-macos-client.sh
#   build/macos/expected-strings.txt: what check-bundle-strings.py compares a built bundle and
#   README with, one line per string: <what>\t<key>\t<lang>\t<text>
# --check: changes nothing, fails if any of these differs from what it would write.
#
# From the probe probe-camera-mac (f921172), without what waits for the Developer ID signing
# (the host's NSSystemExtensionUsageDescription, the kit READMEs' signing sentence, the
# Gatekeeper rows): the unsigned build offers no server camera.
import re
import sys
from pathlib import Path

LANG = {"en": "en", "zh": "zh-Hans", "ja": "ja", "fr": "fr"}
ORDER = ("en", "zh-Hans", "ja", "fr")
CLIENT_KEYS = ("NSCameraUsageDescription", "NSMicrophoneUsageDescription")

# README lines write Latin words and digits next to Japanese without a space
JA_SPACE = re.compile("(?<=[A-Za-z0-9])[ ](?=[　-ヿ一-鿿＀-￯])"
                      "|(?<=[　-ヿ一-鿿＀-￯])[ ](?=[A-Za-z0-9])")


def lang_lines(text, where):
    out = {}
    for line in text.splitlines():
        m = re.match(r"^- (en|zh|ja|fr): (.+)$", line)
        if m:
            out[LANG[m.group(1)]] = m.group(2)
    if sorted(out) != sorted(ORDER):
        sys.exit(f"{where}: lines for {sorted(out)}, want en, zh, ja, fr")
    return out


def po_usage(path):
    """{key: {lang: text}} from its "## <key>" sections"""
    text = Path(path).read_text(encoding="utf-8")
    out = {}
    for key in CLIENT_KEYS:
        m = re.search(rf"^## {key}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
        if not m:
            sys.exit(f"{path}: no section {key}")
        out[key] = lang_lines(m.group(1), f"{path} {key}")
    return out


def readme_style(lang, text):
    if lang == "fr":
        return text.replace("’", "'")
    if lang == "ja":
        return JA_SPACE.sub("", text)
    return text


def strings_file(lang, pairs):
    out = f"/* FreeRDP.app, {lang} (made by build/macos/make-strings.py) */\n"
    for key, value in pairs:
        esc = value.replace("\\", "\\\\").replace('"', '\\"')
        out += f'"{key}" = "{esc}";\n'
    return out


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
    if len(args) != 3:
        sys.exit("usage: make-strings.py [--check] <PO usage descriptions> <PO README draft> <kit dir>")
    client = po_usage(args[0])
    readme = {lang: readme_style(lang, text)
              for lang, text in lang_lines(Path(args[1]).read_text(encoding="utf-8"), args[1]).items()}
    kit = Path(args[2])
    files = {}
    for lang in ORDER:
        files[kit / f"build/macos/client-lproj/{lang}.lproj/InfoPlist.strings"] = strings_file(
            lang, [(key, client[key][lang]) for key in CLIENT_KEYS])
    plist = kit / "build/macos/client-Info.plist"
    text = plist.read_text(encoding="utf-8")
    for key in CLIENT_KEYS:
        text = set_plist_line(text, key, client[key]["en"])
    files[plist] = text
    files[kit / "build/macos/client-README-camera.txt"] = "".join(readme[lang] + "\n" for lang in ORDER)
    lines = [f"client\t{key}\t{lang}\t{client[key][lang]}" for key in CLIENT_KEYS for lang in ORDER]
    lines += [f"readme\tcamera\t{lang}\t{readme[lang]}" for lang in ORDER]
    files[kit / "build/macos/expected-strings.txt"] = "\n".join(lines) + "\n"
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
