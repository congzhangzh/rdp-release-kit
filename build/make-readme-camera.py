#!/usr/bin/env python3
# Makes the Windows, Linux and macOS camera cells of the four kit READMEs' host table, and the
# macOS client's camera line in pins.notes, from the PO's drafts, byte for byte (never retyped),
# as build/macos/make-strings.py does for the Mac's strings:
#
#   make-readme-camera.py [--check] [--on-demand] <PO Windows draft> <PO macOS draft>
#                         <PO R2 texts> <kit dir>
#
#   <PO Windows draft> rdp-product-plan/drafts/readme-windows-camera.v3.md (v2: the camera is
#                      "FreeRDP Camera"; Windows lists it with its own " (Windows Virtual
#                      Camera)"; v3: the camera privacy sentence at the end): the cell, en/zh/ja/fr
#                      ("- <lang>: <text>" lines)
#   <PO macOS draft>   rdp-product-plan/drafts/readme-mac-server-camera-unsigned.v1.md: the macOS
#                      server's cell while the release is signed ad hoc (no server camera: a
#                      CoreMediaIO system extension needs the Developer ID), en/zh/ja/fr
#   <PO R2 texts>      rdp-product-plan/drafts/r2-camera-texts.v1.md: "## 1." the macOS client's
#                      release line (en), which ends pins.notes' "product macos" row after "; ";
#                      "## 2." the Linux server's cell, en/zh/ja/fr; v2 adds "## 3." the clients'
#                      camera paragraph, en/zh/ja/fr (how to turn the camera on)
#
# The cells go in the Windows, Linux and macOS columns of a "Camera" row of the "Shadow server"
# table (README.md, README.zh.md, README.ja.md, README.fr.md): the row is added before the table's
# last row ("Tested in CI"), or its three cells are replaced.
# The clients' paragraph (section 3) goes in the Download section, after the paragraph that starts
# with the latest release's link ("**["), between the markers <!-- camera-client --> and
# <!-- /camera-client --> (GitHub shows neither): added once, then the text between them replaced.
#
# The README style rule (the RM, 2026-11-27): a README cell takes its target README's style.
# README.fr.md writes ASCII apostrophes and NBSP before ":" and ";": U+2019 becomes "'" and a plain
# space before ":" or ";" a NBSP. README.ja.md writes no space between Latin words and Japanese.
# These are the only changes made to the draft's bytes.
#
# The draft's on-demand sentence ("The client's camera runs only while an app reads the virtual
# camera.", the last but one since v3) is true only once the camera runs on demand (SOURCE_START/STOP) and a CI step proved
# it: ON_DEMAND_PROVEN below was False, and the sentence left out, until probe-camera-winshadow's
# on-demand step passed (7ff8628, on windows-2025 and windows-11-arm). --on-demand writes the
# cell with it whatever ON_DEMAND_PROVEN says.
#
# --check: changes nothing, fails if a README differs from what it would write.
import re
import sys
from pathlib import Path

# flip to True only in the commit that cites the green on-demand step (run id)
ON_DEMAND_PROVEN = True

LANGS = ("en", "zh", "ja", "fr")
README = {"en": "README.md", "zh": "README.zh.md", "ja": "README.ja.md", "fr": "README.fr.md"}
# the row's first cell: the cell's own first word(s), before " (Windows)" / "（Windows）"
LABEL = {"en": "Camera", "zh": "摄像头", "ja": "カメラ", "fr": "Caméra"}
# the on-demand sentence, cut where it stands (once, whole) and nowhere else
ON_DEMAND = {
    "en": "The client's camera runs only while an app reads the virtual camera.",
    "zh": "只有应用在读取虚拟摄像头时，客户端的摄像头才会开启。",
    "ja": "クライアントのカメラは、アプリが仮想カメラを読んでいる間だけオンになります。",
    "fr": "La caméra du client ne fonctionne que pendant qu'une application lit la caméra virtuelle.",
}

JA_SPACE = re.compile("(?<=[A-Za-z0-9])[ ](?=[　-ヿ一-鿿＀-￯])"
                      "|(?<=[　-ヿ一-鿿＀-￯])[ ](?=[A-Za-z0-9])")


def readme_style(lang, text):
    if lang == "fr":
        text = text.replace("’", "'")
        return re.sub(r" (?=[:;])", " ", text)
    if lang == "ja":
        return JA_SPACE.sub("", text)
    return text


def po_cells(path):
    out = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        m = re.match(r"^- (en|zh|ja|fr): (.+)$", line)
        if m:
            out[m.group(1)] = m.group(2)
    if sorted(out) != sorted(LANGS):
        sys.exit(f"{path}: cells for {sorted(out)}, want en, zh, ja, fr")
    return out


def po_sections(path):
    """{"1": {lang: text}, "2": {...}} from the "## <n>." sections"""
    out, sec = {}, None
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        m = re.match(r"^## (\d+)\.", line)
        if m:
            sec = m.group(1)
            continue
        m = re.match(r"^- (en|zh|ja|fr): (.+)$", line)
        if m and sec:
            out.setdefault(sec, {})[m.group(1)] = m.group(2)
    if (sorted(out.get("1", {})) != ["en"] or sorted(out.get("2", {})) != sorted(LANGS)
            or sorted(out.get("3", {})) != sorted(LANGS)):
        sys.exit(f"{path}: want section 1 in en, sections 2 and 3 in en, zh, ja, fr")
    return out


# pins.notes: the macOS client's row ends with "; " and the PO's release line
def pins_notes(text, line):
    lines = text.split("\n")
    rows = [i for i, l in enumerate(lines) if l.startswith("product macos ")]
    if len(rows) != 1:
        sys.exit(f"pins.notes: {len(rows)} 'product macos' rows, want 1")
    row = lines[rows[0]]
    if row.endswith("; " + line):
        return text
    at = row.rfind("; macOS client: camera")
    lines[rows[0]] = (row[:at] if at >= 0 else row) + "; " + line
    return "\n".join(lines)


def plain_cell(lang, text, what):
    text = readme_style(lang, text)
    if "|" in text:
        sys.exit(f"{lang}: a '|' in the {what} cell would break the table")
    return text


def cell(lang, text, on_demand):
    text = readme_style(lang, text)
    sentence = readme_style(lang, ON_DEMAND[lang])
    if text.count(sentence) != 1:
        sys.exit(f"{lang}: the draft has the on-demand sentence {text.count(sentence)} times, want once: {sentence!r}")
    if not on_demand:
        at = text.index(sentence)
        # with the space that joins it to the next sentence (zh and ja have none)
        end = at + len(sentence)
        if text[end:end + 1] == " ":
            end += 1
        text = (text[:at] + text[end:]).rstrip(" ")
    if "|" in text:
        sys.exit(f"{lang}: a '|' would break the table")
    return text


def host_table(lines):
    """(first, last) line index of the shadow server table: its header row starts "| | Windows" """
    for i, line in enumerate(lines):
        if line.startswith("| | Windows"):
            j = i
            while j + 1 < len(lines) and lines[j + 1].startswith("|"):
                j += 1
            return i, j
    return None


def update(text, lang, value, linux, mac):
    lines = text.split("\n")
    span = host_table(lines)
    if not span:
        sys.exit(f"{README[lang]}: no shadow server table (a row starting \"| | Windows\")")
    first, last = span
    label = LABEL[lang]
    for i in range(first + 2, last + 1):
        cells = lines[i].split("|")
        if cells[1].strip() == label:
            cells[2] = f" {value} "
            cells[3] = f" {linux} "
            cells[4] = f" {mac} "
            lines[i] = "|".join(cells)
            return "\n".join(lines)
    lines.insert(last, f"| {label} | {value} | {linux} | {mac} |")
    return "\n".join(lines)


CLIENT_OPEN, CLIENT_CLOSE = "<!-- camera-client -->", "<!-- /camera-client -->"


def client_paragraph(text, lang, value):
    """the clients' camera paragraph between its markers, after the latest release's paragraph"""
    lines = text.split("\n")
    block = [CLIENT_OPEN, value, CLIENT_CLOSE]
    opens = [i for i, l in enumerate(lines) if l == CLIENT_OPEN]
    closes = [i for i, l in enumerate(lines) if l == CLIENT_CLOSE]
    if opens or closes:
        if len(opens) != 1 or len(closes) != 1 or closes[0] < opens[0]:
            sys.exit(f"{README[lang]}: want one {CLIENT_OPEN} before one {CLIENT_CLOSE}")
        lines[opens[0]:closes[0] + 1] = block
        return "\n".join(lines)
    starts = [i for i, l in enumerate(lines) if l.startswith("**[")]
    if not starts:
        sys.exit(f"{README[lang]}: no paragraph starting with the latest release's link (\"**[\")")
    end = starts[0]
    while end < len(lines) and lines[end].strip():
        end += 1
    lines[end:end] = [""] + block
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    check = "--check" in args
    on_demand = ON_DEMAND_PROVEN or ("--on-demand" in args)
    args = [a for a in args if a not in ("--check", "--on-demand")]
    if len(args) != 4:
        sys.exit("usage: make-readme-camera.py [--check] [--on-demand] <Windows draft> <macOS draft> "
                 "<R2 texts> <kit>")
    cells = po_cells(args[0])
    mac = po_cells(args[1])
    r2 = po_sections(args[2])
    kit = Path(args[3])
    differs = []
    targets = [(kit / README[lang], lang) for lang in LANGS] + [(kit / "pins.notes", None)]
    for path, lang in targets:
        old = path.read_bytes().decode("utf-8")
        if lang is None:
            new = pins_notes(old, r2["1"]["en"])
        else:
            new = update(old, lang, cell(lang, cells[lang], on_demand),
                         plain_cell(lang, r2["2"][lang], "Linux"), plain_cell(lang, mac[lang], "macOS"))
            new = client_paragraph(new, lang, readme_style(lang, r2["3"][lang]))
        if new.encode("utf-8") == old.encode("utf-8"):
            continue
        if check:
            differs.append(path.name)
        else:
            path.write_bytes(new.encode("utf-8"))
            print(f"wrote {path}")
    if differs:
        sys.exit("differs from the draft: " + ", ".join(differs))


if __name__ == "__main__":
    main()
