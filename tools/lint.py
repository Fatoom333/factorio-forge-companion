r"""Check what can be checked without the game.

Syntax, locale parity and functions defined twice do not need Factorio running,
and each has caught something real: a window that crashed on an element it
looked for in the wrong place, three functions silently defined twice by a bad
edit, and locale keys drifting apart between the two languages.

Needs `lupa` for the Lua parsing, so it runs under the factorio-forge
environment rather than a bare interpreter:

    ..actorio-forge\.venv\Scripts\python.exe tools\lint.py
"""
import json
from pathlib import Path

import lupa

MOD = Path(__file__).resolve().parent.parent
lua = lupa.LuaRuntime(unpack_returned_tuples=True)

ok = True
for path in sorted(MOD.rglob("*.lua")):
    source = path.read_text(encoding="utf-8")
    try:
        # Compiled directly rather than embedded in a Lua string: JSON escapes
        # non-ASCII as \uXXXX, which Lua does not read, so a Cyrillic comment
        # made this report a syntax error in a file that was perfectly good.
        lua.compile(source)
        print(f"  OK      {path.relative_to(MOD)}")
    except Exception as exc:
        ok = False
        print(f"  FAILED  {path.relative_to(MOD)}: {exc}")

print()
import re as _re

print("=== no function is defined twice in one file ===")
_dupes = 0
for _path in sorted(MOD.rglob("*.lua")):
    _seen = {}
    for _n, _line in enumerate(_path.read_text(encoding="utf-8").splitlines(), 1):
        _m = _re.match(r"\s*(?:local\s+)?function\s+([\w.:]+)\s*\(", _line)
        if _m:
            _name = _m.group(1)
            if _name in _seen:
                print(f"  DUPLICATE  {_path.name}: {_name} at lines {_seen[_name]} and {_n}")
                _dupes += 1
            else:
                _seen[_name] = _n
if _dupes == 0:
    print("  none")
print()

print("=== info.json is valid JSON ===")
info = json.loads((MOD / "info.json").read_text(encoding="utf-8"))
for key in ("name", "version", "title", "author", "factorio_version", "dependencies"):
    print(f"  {key:18} {info.get(key)}")

print()
print("=== locale files parse as ini-ish sections ===")
for cfg in sorted(MOD.rglob("*.cfg")):
    lines = [l for l in cfg.read_text(encoding="utf-8").splitlines() if l.strip()]
    section = [l for l in lines if l.startswith("[")]
    keys = [l.split("=")[0] for l in lines if "=" in l]
    print(f"  {cfg.relative_to(MOD)}  sections={len(section)} keys={len(keys)}")

en = {l.split("=")[0] for l in (MOD / "locale/en/strings.cfg").read_text(encoding="utf-8").splitlines() if "=" in l}
ru = {l.split("=")[0] for l in (MOD / "locale/ru/strings.cfg").read_text(encoding="utf-8").splitlines() if "=" in l}
print(f"  keys only in en: {sorted(en - ru) or 'none'}")
print(f"  keys only in ru: {sorted(ru - en) or 'none'}")

print()
print("=== every locale key the code uses exists ===")
import re
used = set()
for path in MOD.rglob("*.lua"):
    used |= set(re.findall(r'\{\s*"forge\.([\w-]+)"', path.read_text(encoding="utf-8")))
missing = sorted(used - en)
print(f"  used by code: {len(used)}")
print(f"  missing from locale: {missing or 'none'}")

raise SystemExit(0 if ok and not missing and not (en ^ ru) else 1)
