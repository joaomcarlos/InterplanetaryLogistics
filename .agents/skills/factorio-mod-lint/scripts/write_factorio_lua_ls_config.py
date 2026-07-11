#!/usr/bin/env python3
"""Write a Lua Language Server config suited for Factorio mods."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence


FACTORIO_GLOBALS = [
    "commands",
    "data",
    "defines",
    "game",
    "helpers",
    "localised_print",
    "log",
    "mods",
    "prototypes",
    "rcon",
    "remote",
    "rendering",
    "script",
    "serpent",
    "settings",
    "storage",
    "table_size",
]


def load_existing(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def merge_config(existing: dict[str, object]) -> dict[str, object]:
    config = dict(existing)
    config["runtime.version"] = "Lua 5.2"
    globals_value = config.get("diagnostics.globals", [])
    if not isinstance(globals_value, list):
        globals_value = []
    globals_set = {item for item in globals_value if isinstance(item, str)}
    globals_set.update(FACTORIO_GLOBALS)
    config["diagnostics.globals"] = sorted(globals_set)
    config.setdefault("workspace.checkThirdParty", False)
    return config


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create or update .luarc.json for Factorio Lua 5.2 globals.")
    parser.add_argument("mod_path", nargs="?", default=".", help="Path to the unpacked Factorio mod directory.")
    parser.add_argument("--output", help="Output config path. Defaults to <mod_path>/.luarc.json.")
    parser.add_argument("--stdout", action="store_true", help="Print the merged config instead of writing it.")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    mod_path = Path(args.mod_path).resolve()
    output = Path(args.output).resolve() if args.output else mod_path / ".luarc.json"
    try:
        existing = load_existing(output)
        merged = merge_config(existing)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    text = json.dumps(merged, indent=2, sort_keys=True) + "\n"
    if args.stdout:
        print(text, end="")
        return 0
    output.write_text(text, encoding="utf-8")
    print(f"Wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
