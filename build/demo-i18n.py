#!/usr/bin/env python3
"""Adds the page's other languages to demo.json, from build/demo-i18n.json:

    build/demo-i18n.py <demo.json> [<demo-i18n.json>]

Every entry of videos, clients, windows and mac gets "i18n": {"zh": {...}, "ja": {...},
"fr": {...}}, each with the title and caption whose English text demo-i18n.json knows; the
English "title" and "caption" stay. A text it doesn't know is left out, so the page shows
English there (freerdp-web-f8, 2026-11-03: a missing language or field falls back to English).
Prints how many entries got each language and the English texts that have none.
"""
import json, os, sys

demo = sys.argv[1]
table = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "demo-i18n.json")
d = json.load(open(demo, encoding="utf-8"))
t = json.load(open(table, encoding="utf-8"))
missing, count = set(), {}
for key in ("videos", "clients", "windows", "mac"):
    for e in d.get(key, []):
        i18n = {}
        for field, src in (("title", t["titles"]), ("caption", t["captions"])):
            text = e.get(field)
            if not text:
                continue
            if text not in src:
                missing.add(f"{field}: {text[:70]}")
                continue
            for lang, v in src[text].items():
                i18n.setdefault(lang, {})[field] = v
        if i18n:
            e["i18n"] = i18n
            for lang in i18n:
                count[lang] = count.get(lang, 0) + 1
json.dump(d, open(demo + ".new", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
os.replace(demo + ".new", demo)
print("demo-i18n: entries with " + ", ".join(f"{k} {v}" for k, v in sorted(count.items())))
for m in sorted(missing):
    print(f"demo-i18n: no translation (English stays) for {m}")
