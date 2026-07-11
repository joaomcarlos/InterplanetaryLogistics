#!/usr/bin/env python3
"""Check literal LocalisedString references against Factorio locale cfg files."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REFERENCE_RE = re.compile(r"\{\s*[\"']([A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+)[\"']")


def read_locale_keys(root: Path) -> tuple[set[str], list[str]]:
    keys: set[str] = set()
    errors: list[str] = []
    for path in sorted((root / "locale").glob("**/*.cfg")):
        section: str | None = None
        for line_number, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
            line = raw.strip()
            if not line or line.startswith(("#", ";")):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1].strip()
                continue
            if "=" not in line or section is None:
                continue
            name = line.split("=", 1)[0].strip()
            full = f"{section}.{name}"
            if full in keys:
                errors.append(f"{path}:{line_number}: duplicate locale key {full}")
            keys.add(full)
    return keys, errors


def read_references(root: Path) -> dict[str, list[str]]:
    references: dict[str, list[str]] = {}
    for path in sorted(root.glob("**/*.lua")):
        if any(part.startswith(".") for part in path.relative_to(root).parts):
            continue
        for line_number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            for match in REFERENCE_RE.finditer(line):
                references.setdefault(match.group(1), []).append(f"{path}:{line_number}")
    return references


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mod_folder", type=Path)
    parser.add_argument("--prefix", action="append", default=[], help="Locale section prefix to validate")
    args = parser.parse_args()
    root = args.mod_folder.resolve()
    keys, errors = read_locale_keys(root)
    references = read_references(root)
    prefixes = tuple(prefix + "." for prefix in args.prefix)

    for key, locations in sorted(references.items()):
        if key.endswith(("-", ".")):
            continue
        if prefixes and not key.startswith(prefixes):
            continue
        if not prefixes and key.split(".", 1)[0] not in {item.split(".", 1)[0] for item in keys}:
            continue
        if key not in keys:
            errors.append(f"missing locale key {key}; referenced at {', '.join(locations)}")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(f"locale keys: OK ({len(references)} literal references, {len(keys)} definitions)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
