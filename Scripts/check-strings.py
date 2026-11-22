#!/usr/bin/env python3
"""ソース中の L("…") のキーが、Localizable.xcstrings に英語訳付きで登録されているか確かめる。

使い方: python3 Scripts/check-strings.py
"""
import glob
import json
import re
import sys

catalog = json.load(open("Tansu/Localizable.xcstrings"))["strings"]
keys = set()
for path in glob.glob("Tansu/**/*.swift", recursive=True):
    source = open(path).read()
    keys.update(m.group(1) for m in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"', source))

missing = sorted(k for k in keys if "en" not in catalog.get(k, {}).get("localizations", {}))
unused = sorted(k for k in catalog if k not in keys)
for key in missing:
    print("英語訳がありません:", key)
for key in unused:
    print("使われていません:", key)
sys.exit(1 if missing else 0)
