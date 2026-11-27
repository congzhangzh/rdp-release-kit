#!/usr/bin/env python3
# Makes the Mac bundles' usage strings from their sources, byte for byte (never retyped):
#
#   make-strings.py [--check] <PO strings draft> <PO usage descriptions> <PO README draft>
#                   <PO README signing draft> <PO Gatekeeper draft> <kit dir>
#
#   <PO strings draft>   rdp-product-plan/drafts/mac-signing-strings.v1.md, section 1:
#                        NSSystemExtensionUsageDescription of FreeRDP-Shadow.app, en/zh/ja/fr
#   <PO usage descriptions>  rdp-product-plan/drafts/mac-usage-descriptions.v1.md: the client's
#                        NSCameraUsageDescription and NSMicrophoneUsageDescription, en/zh/ja/fr
#   <PO README draft>    rdp-product-plan/drafts/readme-mac-camera.v1.md: the Mac client
#                        README's camera paragraph, en/zh/ja/fr
#   <PO README signing draft>  rdp-product-plan/drafts/readme-mac-signing.v1.md: the kit
#                        READMEs' signing sentence (en/zh/ja/fr) and README.md's check-macos.sh
#                        cell
#   <PO Gatekeeper draft>  rdp-product-plan/drafts/readme-mac-gatekeeper.v1.md: README.md's
#                        Gatekeeper row and kit.yml's macOS client release-notes row, variants A
#                        and B (GATEKEEPER below picks one, or neither)
#
# The README style rule (the RM, 2026-11-27): a README cell takes its target README's style.
# README.fr.md writes ASCII apostrophes (and NBSP before ":" and ";"), so a fr README cell gets
# U+2019 turned into "'" here; only the Info.plist strings keep U+2019. README.ja.md writes no
# space between Latin words and Japanese (a `code span` keeps its spaces). These are the only
# changes made to a source's bytes, and the expected file holds the result.
#
# Writes, in the kit:
#   build/macos/host-lproj/{zh-Hans,ja,fr}.lproj/InfoPlist.strings   (en is in host-Info.plist)
#   build/macos/client-lproj/{en,zh-Hans,ja,fr}.lproj/InfoPlist.strings
#   the en values in build/macos/host-Info.plist and build/macos/client-Info.plist
#   build/macos/client-README-camera.txt: the four README lines, appended to the client
#   archive's README.txt by build-macos-client.sh
#   README.md, README.zh.md, README.ja.md, README.fr.md: the old "signed ad hoc" sentence
#   replaced by the signing sentence (on one line); README.md's check-macos.sh cell; with
#   GATEKEEPER set, README.md's Gatekeeper row and kit.yml's macOS client row
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


CLIENT_KEYS = ("NSCameraUsageDescription", "NSMicrophoneUsageDescription")


def po_usage(path):
    """{key: {lang: text}} from its "## <key>" sections"""
    text = Path(path).read_text(encoding="utf-8")
    out = {}
    for key in CLIENT_KEYS:
        m = re.search(rf"^## {key}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
        if not m:
            sys.exit(f"{path}: no section {key}")
        out[key] = {}
        for line in m.group(1).splitlines():
            lm = re.match(r"^- (en|zh|ja|fr): (.+)$", line)
            if lm:
                out[key][LANG[lm.group(1)]] = lm.group(2)
        if sorted(out[key]) != sorted(LANG.values()):
            sys.exit(f"{path}: {key} has {sorted(out[key])}, want en, zh, ja, fr")
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


# README.md's Gatekeeper row and kit.yml's macOS client release-notes row say how a browser
# download opens: true only once the probe's signed job proved it. Until then both stay as they
# are and are no generated text (None). The held patch sets the variant the signed run supports,
# together with the xattr step's removal: "A" (remove-quarantine-step.v4.patch: the whole archive
# opens) or "B" (v5: the apps open, freerdp-tk.command is still refused).
GATEKEEPER = None

README_FILE = {"en": "README.md", "zh-Hans": "README.zh.md", "ja": "README.ja.md", "fr": "README.fr.md"}
# the sentence each README had while the apps were signed ad hoc (it may wrap over two lines)
OLD_SIGNING = {
    "en": r"Both are signed ad hoc, so macOS\s+asks for the two permissions again after each update\.",
    "zh-Hans": r"两者都使用临时（ad hoc）签名，\s*所以每次更新后 macOS 都会再次询问这两项权限。",
    "ja": r"どちらもアドホック署名のため、\s*更新のたびにmacOSが2つの許可を再度求めます。",
    "fr": r"Les deux sont signés ad hoc, si bien que macOS\s+redemande les deux autorisations après chaque mise à jour\.",
}


# README.ja.md writes Latin words and digits next to Japanese without a space; a `code span`
# keeps its spaces (the PO's ja cell, 2026-11-27)
JA_SPACE = re.compile("(?<=[A-Za-z0-9])[ ](?=[\u3000-\u30ff\u4e00-\u9fff\uff00-\uffef])"
                      "|(?<=[\u3000-\u30ff\u4e00-\u9fff\uff00-\uffef])[ ](?=[A-Za-z0-9])")


def readme_style(lang, text):
    """a README cell in its target README's style: fr READMEs write ASCII apostrophes, ja ones
    no space between Latin and Japanese"""
    if lang == "fr":
        return text.replace("\u2019", "'")
    if lang == "ja":
        return JA_SPACE.sub("", text)
    return text


def po_signing(path):
    text = Path(path).read_text(encoding="utf-8")
    m = re.search(r"^## The sentence ×4\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not m:
        sys.exit(f"{path}: no section 'The sentence ×4'")
    sentence = {}
    for line in m.group(1).splitlines():
        lm = re.match(r"^- (en|zh|ja|fr): (.+)$", line)
        if lm:
            sentence[LANG[lm.group(1)]] = lm.group(2)
    if sorted(sentence) != sorted(LANG.values()):
        sys.exit(f"{path}: the sentence for {sorted(sentence)}, want en, zh, ja, fr")
    cell = re.search(r'"an ad-hoc signature" → "([^"]+)"', text)
    if not cell:
        sys.exit(f"{path}: no check-macos.sh cell")
    return sentence, cell.group(1)


# kit.yml's macOS client row ("| macOS Apple Silicon |"): the text after this is the variant's (in a shell
# double-quoted string there, where a backtick is written \`)
KITYML = ".github/workflows/kit.yml"
KITYML_ANCHOR = "(or \\`bin/sdl-freerdp /v:server /u:user\\`)"


def po_gatekeeper(path):
    """{"A": (README row, kit.yml tail), "B": (...)} from the PO's Gatekeeper draft"""
    text = Path(path).read_text(encoding="utf-8")
    out = {}
    for section, index in (("README.md:175 row", 0), ("kit.yml:", 1)):
        m = re.search(rf"^## {re.escape(section)}.*?\n(.*?)(?=^## |\Z)", text, re.S | re.M)
        if not m:
            sys.exit(f"{path}: no section '{section}'")
        for line in m.group(1).splitlines():
            lm = re.match(r"^- (A|B): (.+)$", line)
            if lm:
                out.setdefault(lm.group(1), [None, None])[index] = lm.group(2)
    if sorted(out) != ["A", "B"] or any(None in v for v in out.values()):
        sys.exit(f"{path}: want a README row and a kit.yml text for A and B, got {out}")
    return {k: tuple(v) for k, v in out.items()}


def kityml_written(text):
    """the PO's text as kit.yml holds it: in a double-quoted shell string"""
    return text.replace("`", "\\`")


def strings_file(bundle, lang, pairs):
    """pairs: (key, value) in order"""
    out = f"/* {bundle}, {lang} (made by test/probe-camera-mac/make-strings.py) */\n"
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
    if len(args) != 6:
        sys.exit("usage: make-strings.py [--check] <PO strings draft> <PO usage descriptions> "
                 "<PO README draft> <PO README signing draft> <kit dir>")
    host = po_section1(args[0])
    client = po_usage(args[1])
    readme = {lang: readme_style(lang, text) for lang, text in po_readme(args[2]).items()}
    sentence, cell = po_signing(args[3])
    gatekeeper = po_gatekeeper(args[4])
    sentence = {lang: readme_style(lang, text) for lang, text in sentence.items()}
    kit = Path(args[5])
    files = {}
    for lang in ("zh-Hans", "ja", "fr"):
        files[kit / f"build/macos/host-lproj/{lang}.lproj/InfoPlist.strings"] = strings_file(
            "FreeRDP-Shadow.app", lang, [("NSSystemExtensionUsageDescription", host[lang])])
    for lang in ("en", "zh-Hans", "ja", "fr"):
        files[kit / f"build/macos/client-lproj/{lang}.lproj/InfoPlist.strings"] = strings_file(
            "FreeRDP.app", lang, [(key, client[key][lang]) for key in CLIENT_KEYS])
    edits = [("host-Info.plist", "NSSystemExtensionUsageDescription", host["en"])]
    edits += [("client-Info.plist", key, client[key]["en"]) for key in CLIENT_KEYS]
    for name, key, value in edits:
        p = kit / "build/macos" / name
        files[p] = set_plist_line(files.get(p) or p.read_text(encoding="utf-8"), key, value)
    order = ("en", "zh-Hans", "ja", "fr")
    files[kit / "build/macos/client-README-camera.txt"] = "".join(readme[lang] + "\n" for lang in order)
    lines = [f"host\tNSSystemExtensionUsageDescription\t{lang}\t{host[lang]}" for lang in ("en", "zh-Hans", "ja", "fr")]
    lines += [f"client\t{key}\t{lang}\t{client[key][lang]}" for key in CLIENT_KEYS for lang in ("en", "zh-Hans", "ja", "fr")]
    lines += [f"readme\tcamera\t{lang}\t{readme[lang]}" for lang in order]
    # the kit's own READMEs: each text must be in that file (check-bundle-strings.py kit-readme)
    for lang in order:
        p = kit / README_FILE[lang]
        text = files.get(p) or p.read_text(encoding="utf-8")
        if sentence[lang] not in text:
            text, n = re.subn(OLD_SIGNING[lang], lambda _: sentence[lang], text)
            if n != 1:
                sys.exit(f"{p}: the old signing sentence found {n} times, want 1")
        if lang == "en":
            if GATEKEEPER:
                row = gatekeeper[GATEKEEPER][0]
                text, n = re.subn(r"^\| macOS, a browser download \|.*\|$", lambda _: row, text, flags=re.M)
                if n != 1:
                    sys.exit(f"{p}: the Gatekeeper row found {n} times, want 1")
            if cell not in text:
                text, n = re.subn(r"an ad-hoc signature", lambda _: cell, text)
                if n != 1:
                    sys.exit(f"{p}: 'an ad-hoc signature' found {n} times, want 1")
        files[p] = text
        lines.append(f"kit-readme\t{README_FILE[lang]}\t{lang}\t{sentence[lang]}")
    if GATEKEEPER:
        lines.append(f"kit-readme\tREADME.md\ten\t{gatekeeper[GATEKEEPER][0]}")
        p = kit / KITYML
        tail = kityml_written(gatekeeper[GATEKEEPER][1])
        text = p.read_text(encoding="utf-8")
        # the macOS client's row only (the Linux row has the same "(or …)")
        text, n = re.subn(r"^(\s*\| macOS Apple Silicon \|[^\n]*?" + re.escape(KITYML_ANCHOR) + r")[^\n]*\|$",
                          lambda m: m.group(1) + tail, text, flags=re.M)
        if n != 1:
            sys.exit(f"{p}: the macOS client row found {n} times, want 1")
        files[p] = text
        lines.append(f"kit-readme\t{KITYML}\ten\t{KITYML_ANCHOR}{tail}")
    lines.append(f"kit-readme\tREADME.md\ten\t{cell}")
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
