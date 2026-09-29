#!/usr/bin/env python3
"""
Localization audit for TranscriptorX UI.

Checks:
1) Every `localizationManager.text("key", ...)` key exists in Localizable.xcstrings with en/es.
2) Every hardcoded UI literal used in SwiftUI constructors exists in Localizable.xcstrings with en/es.

Usage:
  python3 scripts/check_localization.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC_ROOTS = [ROOT / "TranscriptorNative" / "Views", ROOT / "TranscriptorNative" / "App"]
CATALOG = ROOT / "TranscriptorNative" / "Resources" / "Localizable.xcstrings"
IGNORE_PATH_FRAGMENTS = ("demucs_env", "site-packages")

LOCALIZATION_KEY_PATTERN = re.compile(r'localizationManager\.text\("([^"]+)"')
UI_LITERAL_PATTERNS = [
    re.compile(r'Text\("([^"\\]*(?:\\.[^"\\]*)*)"\)'),
    re.compile(r'Button\("([^"\\]*(?:\\.[^"\\]*)*)"\)'),
    re.compile(r'Label\("([^"\\]*(?:\\.[^"\\]*)*)"\)'),
    re.compile(r'TextField\("([^"\\]*(?:\\.[^"\\]*)*)"\)'),
    re.compile(r'\.help\("([^"\\]*(?:\\.[^"\\]*)*)"\)'),
    re.compile(r'\.accessibilityLabel\("([^"\\]*(?:\\.[^"\\]*)*)"\)'),
    re.compile(r'\.accessibilityHint\("([^"\\]*(?:\\.[^"\\]*)*)"\)'),
    re.compile(r'confirmationDialog\("([^"\\]*(?:\\.[^"\\]*)*)"\)'),
]
UI_LITERAL_EXCLUDES = {"", "•", "·", "%"}


def iter_swift_files() -> list[Path]:
    files: list[Path] = []
    for src_root in SRC_ROOTS:
        for path in src_root.rglob("*.swift"):
            if any(fragment in str(path) for fragment in IGNORE_PATH_FRAGMENTS):
                continue
            files.append(path)
    return files


def load_catalog() -> dict:
    return json.loads(CATALOG.read_text(encoding="utf-8"))


def has_en_es(entry: dict) -> bool:
    localizations = entry.get("localizations", {})
    return "en" in localizations and "es" in localizations


def main() -> int:
    files = iter_swift_files()
    catalog = load_catalog()
    strings = catalog.get("strings", {})

    manager_keys: set[str] = set()
    ui_literals: set[str] = set()

    for path in files:
        text = path.read_text(encoding="utf-8", errors="ignore")

        for match in LOCALIZATION_KEY_PATTERN.finditer(text):
            manager_keys.add(match.group(1))

        for pattern in UI_LITERAL_PATTERNS:
            for match in pattern.finditer(text):
                literal = match.group(1)
                if "\\(" in literal:
                    continue
                if literal.strip() in UI_LITERAL_EXCLUDES:
                    continue
                ui_literals.add(literal)

    missing_manager_keys = sorted(k for k in manager_keys if k not in strings)
    missing_literals = sorted(l for l in ui_literals if l not in strings)
    missing_locales = sorted(
        k for k in (manager_keys | ui_literals) if k in strings and not has_en_es(strings[k])
    )

    if not missing_manager_keys and not missing_literals and not missing_locales:
        print("Localization audit passed.")
        print(f"- manager keys: {len(manager_keys)}")
        print(f"- ui literals: {len(ui_literals)}")
        return 0

    print("Localization audit failed.")
    if missing_manager_keys:
        print(f"\nMissing localizationManager keys ({len(missing_manager_keys)}):")
        for key in missing_manager_keys:
            print(f"  - {key}")

    if missing_literals:
        print(f"\nMissing UI literals in catalog ({len(missing_literals)}):")
        for literal in missing_literals:
            print(f"  - {literal}")

    if missing_locales:
        print(f"\nCatalog entries missing en/es locales ({len(missing_locales)}):")
        for key in missing_locales:
            print(f"  - {key}")

    return 1


if __name__ == "__main__":
    sys.exit(main())
