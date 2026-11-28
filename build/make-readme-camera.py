#!/usr/bin/env python3
# Makes the Windows and macOS camera cells of the four kit READMEs' host table from the PO's
# drafts, byte for byte (never retyped), as build/macos/make-strings.py does for the Mac's strings:
#
#   make-readme-camera.py [--check] [--on-demand] <PO Windows draft> <PO macOS draft> <kit dir>
#
#   <PO Windows draft> rdp-product-plan/drafts/readme-windows-camera.v3.md (v2: the camera is
#                      "FreeRDP Camera"; Windows lists it with its own " (Windows Virtual
#                      Camera)"; v3: the camera privacy sentence at the end): the cell, en/zh/ja/fr
#                      ("- <lang>: <text>" lines)
#   <PO macOS draft>   rdp-product-plan/drafts/readme-mac-server-camera-unsigned.v1.md: the macOS
#                      server's cell while the release is signed ad hoc (no server camera: a
#                      CoreMediaIO system extension needs the Developer ID), en/zh/ja/fr
#
# The cells go in the Windows and macOS columns of a "Camera" row of the "Shadow server" table
# (README.md, README.zh.md, README.ja.md, README.fr.md): the row is added before the table's last
# row ("Tested in CI"), the Linux cell "—"; a row that is there already keeps its Linux cell.
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


def update(text, lang, value, mac):
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
            cells[4] = f" {mac} "
            lines[i] = "|".join(cells)
            return "\n".join(lines)
    lines.insert(last, f"| {label} | {value} | — | {mac} |")
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    check = "--check" in args
    on_demand = ON_DEMAND_PROVEN or ("--on-demand" in args)
    args = [a for a in args if a not in ("--check", "--on-demand")]
    if len(args) != 3:
        sys.exit("usage: make-readme-camera.py [--check] [--on-demand] <Windows draft> <macOS draft> <kit>")
    cells = po_cells(args[0])
    mac = po_cells(args[1])
    kit = Path(args[2])
    differs = []
    for lang in LANGS:
        path = kit / README[lang]
        old = path.read_bytes().decode("utf-8")
        mac_cell = readme_style(lang, mac[lang])
        if "|" in mac_cell:
            sys.exit(f"{lang}: a '|' in the macOS cell would break the table")
        new = update(old, lang, cell(lang, cells[lang], on_demand), mac_cell)
        if new.encode("utf-8") == old.encode("utf-8"):
            continue
        if check:
            differs.append(README[lang])
        else:
            path.write_bytes(new.encode("utf-8"))
            print(f"wrote {path}")
    if differs:
        sys.exit("differs from the draft: " + ", ".join(differs))


if __name__ == "__main__":
    main()
