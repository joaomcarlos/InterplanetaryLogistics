#!/usr/bin/env python3
"""Static lint checks for Factorio mods and Factorio's Lua 5.2 runtime."""

from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence


SEVERITY_RANK = {"info": 0, "warning": 1, "error": 2}
DEFAULT_EXCLUDED_DIRS = {
    ".git",
    ".codex",
    ".idea",
    ".vscode",
    "__pycache__",
    "node_modules",
    "output",
    "tmp",
}
ROOT_STAGE_FILES = {
    "settings.lua",
    "settings-updates.lua",
    "settings-final-fixes.lua",
    "data.lua",
    "data-updates.lua",
    "data-final-fixes.lua",
    "control.lua",
}
SETTINGS_STAGE_FILES = {"settings.lua", "settings-updates.lua", "settings-final-fixes.lua"}
DATA_STAGE_FILES = {"data.lua", "data-updates.lua", "data-final-fixes.lua"}
RUNTIME_GLOBALS = ("game", "script", "storage", "remote", "commands", "rcon", "rendering", "prototypes", "helpers")
CORE_LUALIB_REQUIRES = {
    "util",
    "mod-gui",
    "dataloader",
    "noise",
    "circuit-connector-sprites",
    "circuit-connector-generated-definitions",
    "item_sounds",
    "tile_trigger_effects",
}


@dataclass(frozen=True)
class Issue:
    path: str
    line: int
    col: int
    severity: str
    rule: str
    message: str

    def sort_key(self) -> tuple[int, str, int, int, str]:
        return (-SEVERITY_RANK[self.severity], self.path, self.line, self.col, self.rule)


def line_starts(text: str) -> list[int]:
    starts = [0]
    for match in re.finditer("\n", text):
        starts.append(match.end())
    return starts


def line_col(starts: Sequence[int], index: int) -> tuple[int, int]:
    line_index = bisect.bisect_right(starts, index) - 1
    return line_index + 1, index - starts[line_index] + 1


def rel_path(path: Path, root: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.as_posix()


def add_issue(
    issues: list[Issue],
    ignored: set[str],
    root: Path,
    path: Path,
    severity: str,
    rule: str,
    message: str,
    *,
    line: int = 1,
    col: int = 1,
    index: int | None = None,
    starts: Sequence[int] | None = None,
) -> None:
    if rule in ignored:
        return
    if index is not None and starts is not None:
        line, col = line_col(starts, index)
    issues.append(Issue(rel_path(path, root), line, col, severity, rule, message))


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError:
        return path.read_text(encoding="cp1252")


def long_bracket_at(text: str, index: int) -> tuple[int, int] | None:
    if index >= len(text) or text[index] != "[":
        return None
    j = index + 1
    while j < len(text) and text[j] == "=":
        j += 1
    if j < len(text) and text[j] == "[":
        return j - index - 1, j + 1
    return None


def blank_range(chars: list[str], start: int, end: int) -> None:
    for i in range(start, min(end, len(chars))):
        if chars[i] != "\n":
            chars[i] = " "


def mask_lua_source(text: str) -> str:
    """Replace comments and strings with spaces while preserving offsets."""
    chars = list(text)
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("--", i):
            bracket = long_bracket_at(text, i + 2)
            if bracket:
                eq_count, content_start = bracket
                close = "]" + ("=" * eq_count) + "]"
                close_index = text.find(close, content_start)
                end = n if close_index == -1 else close_index + len(close)
                blank_range(chars, i, end)
                i = end
            else:
                end = text.find("\n", i)
                end = n if end == -1 else end
                blank_range(chars, i, end)
                i = end
            continue
        if text[i] in ("'", '"'):
            quote = text[i]
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == quote:
                    j += 1
                    break
                j += 1
            blank_range(chars, i, j)
            i = j
            continue
        if text[i] == "[":
            bracket = long_bracket_at(text, i)
            if bracket:
                eq_count, content_start = bracket
                close = "]" + ("=" * eq_count) + "]"
                close_index = text.find(close, content_start)
                end = n if close_index == -1 else close_index + len(close)
                blank_range(chars, i, end)
                i = end
                continue
        i += 1
    return "".join(chars)


WORD_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")


def iter_words(masked: str, start: int = 0, end: int | None = None) -> Iterator[re.Match[str]]:
    yield from WORD_RE.finditer(masked, start, len(masked) if end is None else end)


def find_matching_function_end(masked: str, function_index: int, limit: int | None = None) -> int | None:
    depth = 0
    for match in iter_words(masked, function_index, limit):
        word = match.group(0)
        if word in {"function", "then", "do", "repeat"}:
            depth += 1
        elif word in {"end", "until"}:
            if depth > 0:
                depth -= 1
            if depth == 0:
                return match.end()
    return None


def call_pattern(dotted_name: str) -> re.Pattern[str]:
    parts = [re.escape(part) for part in dotted_name.split(".")]
    return re.compile(r"\b" + r"\s*\.\s*".join(parts) + r"\s*\(")


def iter_call_open_parens(masked: str, dotted_name: str) -> Iterator[tuple[int, int]]:
    for match in call_pattern(dotted_name).finditer(masked):
        yield match.start(), match.end() - 1


def split_call_args(masked: str, open_paren: int) -> tuple[list[tuple[int, int]], int | None]:
    args: list[tuple[int, int]] = []
    arg_start = open_paren + 1
    paren_depth = 0
    brace_depth = 0
    bracket_depth = 0
    block_depth = 0
    i = open_paren + 1
    n = len(masked)

    while i < n:
        word_match = WORD_RE.match(masked, i)
        if word_match:
            word = word_match.group(0)
            if word in {"function", "then", "do", "repeat"}:
                block_depth += 1
            elif word in {"end", "until"} and block_depth > 0:
                block_depth -= 1
            i = word_match.end()
            continue

        char = masked[i]
        if char == "(":
            paren_depth += 1
        elif char == ")":
            if paren_depth == 0 and brace_depth == 0 and bracket_depth == 0 and block_depth == 0:
                args.append((arg_start, i))
                return args, i
            if paren_depth > 0:
                paren_depth -= 1
        elif char == "{":
            brace_depth += 1
        elif char == "}" and brace_depth > 0:
            brace_depth -= 1
        elif char == "[":
            bracket_depth += 1
        elif char == "]" and bracket_depth > 0:
            bracket_depth -= 1
        elif char == "," and paren_depth == 0 and brace_depth == 0 and bracket_depth == 0 and block_depth == 0:
            args.append((arg_start, i))
            arg_start = i + 1
        i += 1
    return args, None


def strip_span_text(masked: str, span: tuple[int, int]) -> str:
    return masked[span[0] : span[1]].strip()


def parse_short_string(text: str, index: int) -> tuple[str, int] | None:
    if index >= len(text) or text[index] not in ("'", '"'):
        return None
    quote = text[index]
    value: list[str] = []
    i = index + 1
    while i < len(text):
        char = text[i]
        if char == "\\":
            if i + 1 < len(text):
                value.append(text[i + 1])
                i += 2
            else:
                i += 1
            continue
        if char == quote:
            return "".join(value), i + 1
        if char in "\r\n":
            return None
        value.append(char)
        i += 1
    return None


def extract_short_strings(text: str) -> list[str]:
    strings: list[str] = []
    i = 0
    while i < len(text):
        parsed = parse_short_string(text, i)
        if parsed:
            value, end = parsed
            strings.append(value)
            i = end
        else:
            i += 1
    return strings


def normalize_code(code: str) -> str:
    return re.sub(r"\s+", "", code)


def extract_event_names(original_arg: str, masked_arg: str) -> list[str]:
    names = [f"defines.events.{m.group(1)}" for m in re.finditer(r"\bdefines\s*\.\s*events\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)", masked_arg)]
    names.extend(f"custom-input:{value}" for value in extract_short_strings(original_arg))
    if names:
        return names
    normalized = normalize_code(masked_arg)
    return [normalized] if normalized else []


def is_table_constructor(masked_arg: str) -> bool:
    return masked_arg.strip().startswith("{")


def arg_starts_with_function(masked: str, span: tuple[int, int]) -> int | None:
    match = WORD_RE.search(masked, span[0], span[1])
    if match and match.group(0) == "function":
        return match.start()
    return None


def find_first(masked: str, pattern: str, start: int = 0, end: int | None = None) -> re.Match[str] | None:
    return re.search(pattern, masked[start : len(masked) if end is None else end])


def lint_info_json(root: Path, ignored: set[str], issues: list[Issue]) -> dict[str, object] | None:
    path = root / "info.json"
    if not path.exists():
        add_issue(issues, ignored, root, path, "error", "info-json-missing", "Factorio mods require info.json.")
        return None

    try:
        info = json.loads(read_text(path))
    except json.JSONDecodeError as exc:
        add_issue(issues, ignored, root, path, "error", "info-json-invalid", f"info.json is not valid JSON: {exc.msg}.", line=exc.lineno, col=exc.colno)
        return None

    if not isinstance(info, dict):
        add_issue(issues, ignored, root, path, "error", "info-json-root", "info.json must contain a JSON object.")
        return None

    for field in ("name", "version", "title", "author"):
        value = info.get(field)
        if not isinstance(value, str) or not value.strip():
            add_issue(issues, ignored, root, path, "error", "info-json-required-field", f"`{field}` must be a non-empty string.")

    name = info.get("name")
    if isinstance(name, str):
        if len(name) > 100:
            add_issue(issues, ignored, root, path, "error", "info-json-name-length", "`name` must be at most 100 characters for Factorio.")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            add_issue(issues, ignored, root, path, "warning", "info-json-name-portal-chars", "`name` contains characters the mod portal rejects.")

    version = info.get("version")
    if isinstance(version, str):
        version_match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
        if not version_match:
            add_issue(issues, ignored, root, path, "error", "info-json-version-format", "`version` must use number.number.number.")
        else:
            if any(int(part) > 65535 for part in version_match.groups()):
                add_issue(issues, ignored, root, path, "error", "info-json-version-range", "Each `version` number must be 0 through 65535.")

    factorio_version = info.get("factorio_version")
    if factorio_version is None:
        add_issue(issues, ignored, root, path, "warning", "info-json-factorio-version-missing", "`factorio_version` is absent; pin the supported Factorio major.minor line.")
    elif not isinstance(factorio_version, str) or not re.fullmatch(r"\d+\.\d+", factorio_version):
        add_issue(issues, ignored, root, path, "warning", "info-json-factorio-version-format", "`factorio_version` should look like `2.0`.")

    deps = info.get("dependencies")
    if deps is not None:
        if not isinstance(deps, list):
            add_issue(issues, ignored, root, path, "error", "info-json-dependencies-type", "`dependencies` must be an array of strings.")
        else:
            seen_deps: dict[str, str] = {}
            for dep in deps:
                if not isinstance(dep, str):
                    add_issue(issues, ignored, root, path, "error", "info-json-dependency-type", "Each dependency must be a string.")
                    continue
                dep_text = dep.strip()
                match = re.fullmatch(r"(?:(\(\?\)|[?!~])\s*)?([A-Za-z0-9_-]+)(?:\s*(<=|>=|=|<|>)\s*(\d+(?:\.\d+){0,2}))?", dep_text)
                if not match:
                    add_issue(issues, ignored, root, path, "warning", "info-json-dependency-format", f"Dependency `{dep}` does not match the usual Factorio dependency syntax.")
                    continue
                dep_name = match.group(2).lower()
                if dep_name in seen_deps:
                    add_issue(issues, ignored, root, path, "warning", "info-json-dependency-duplicate", f"Dependency `{dep}` duplicates `{seen_deps[dep_name]}`.")
                seen_deps[dep_name] = dep

    if isinstance(name, str) and isinstance(version, str):
        folder = root.name
        exact = name
        versioned = f"{name}_{version}"
        if folder not in {exact, versioned}:
            if re.fullmatch(r".+_\d+\.\d+\.\d+", folder):
                add_issue(issues, ignored, root, path, "warning", "mod-folder-name", f"Folder `{folder}` does not match `{exact}` or `{versioned}`.")
            elif folder.lower() != name.lower():
                add_issue(issues, ignored, root, path, "info", "mod-folder-name", f"Folder `{folder}` differs from info.json name `{name}`.")

    return info


def lint_root_structure(root: Path, ignored: set[str], issues: list[Issue]) -> None:
    has_stage_file = any((root / name).exists() for name in ROOT_STAGE_FILES)
    if not has_stage_file:
        add_issue(issues, ignored, root, root, "warning", "mod-no-stage-files", "No root Factorio stage file found; this mod may only contain metadata.")

    for child in root.iterdir():
        if not child.is_file():
            continue
        lower = child.name.lower()
        if lower in ROOT_STAGE_FILES and child.name != lower:
            add_issue(issues, ignored, root, child, "warning", "root-file-case", f"Factorio auto-load file `{child.name}` should be lowercase `{lower}`.")

    migrations = root / "migrations"
    if migrations.exists():
        for path in migrations.iterdir():
            if path.is_file() and path.suffix.lower() not in {".lua", ".json"}:
                add_issue(issues, ignored, root, path, "warning", "migration-extension", "Migration files should be .lua or .json.")
            if path.is_file() and path.suffix.lower() == ".json":
                try:
                    json.loads(read_text(path))
                except json.JSONDecodeError as exc:
                    add_issue(issues, ignored, root, path, "error", "migration-json-invalid", f"Migration JSON is invalid: {exc.msg}.", line=exc.lineno, col=exc.colno)

    thumbnail = root / "thumbnail.png"
    if thumbnail.exists():
        try:
            with thumbnail.open("rb") as handle:
                header = handle.read(24)
            if not header.startswith(b"\x89PNG\r\n\x1a\n") or len(header) < 24:
                add_issue(issues, ignored, root, thumbnail, "warning", "thumbnail-png", "thumbnail.png exists but is not a valid PNG header.")
            else:
                width, height = struct.unpack(">II", header[16:24])
                if (width, height) != (144, 144):
                    add_issue(issues, ignored, root, thumbnail, "info", "thumbnail-size", f"thumbnail.png is {width}x{height}; Factorio recommends 144x144.")
        except OSError as exc:
            add_issue(issues, ignored, root, thumbnail, "warning", "thumbnail-read", f"Could not read thumbnail.png: {exc}.")


def lint_locale_files(root: Path, ignored: set[str], issues: list[Issue]) -> None:
    locale_root = root / "locale"
    if not locale_root.exists():
        return
    for path in locale_root.rglob("*.cfg"):
        seen: set[tuple[str, str]] = set()
        current_section: str | None = None
        for line_no, line in enumerate(read_text(path).splitlines(), start=1):
            stripped = line.strip()
            if not stripped or stripped.startswith(";") or stripped.startswith("#"):
                continue
            section_match = re.fullmatch(r"\[([^\[\]]+)\]", stripped)
            if section_match:
                current_section = section_match.group(1).strip()
                if not current_section:
                    add_issue(issues, ignored, root, path, "error", "locale-empty-section", "Locale section name is empty.", line=line_no)
                continue
            if "=" not in line:
                add_issue(issues, ignored, root, path, "warning", "locale-malformed-line", "Locale line is neither a section nor key=value.", line=line_no)
                continue
            key, _value = line.split("=", 1)
            key = key.strip()
            if not current_section:
                add_issue(issues, ignored, root, path, "warning", "locale-key-before-section", f"Locale key `{key}` appears before any section.", line=line_no)
                continue
            if not key:
                add_issue(issues, ignored, root, path, "error", "locale-empty-key", "Locale key is empty.", line=line_no)
                continue
            compound = (current_section, key)
            if compound in seen:
                add_issue(issues, ignored, root, path, "warning", "locale-duplicate-key", f"Duplicate locale key `{current_section}.{key}`.", line=line_no)
            seen.add(compound)


def discover_lua_files(root: Path, extra_excludes: Iterable[str]) -> list[Path]:
    excluded = set(DEFAULT_EXCLUDED_DIRS)
    excluded.update(extra_excludes)
    result: list[Path] = []
    for path in root.rglob("*.lua"):
        rel_parts = path.relative_to(root).parts
        if any(part in excluded for part in rel_parts[:-1]):
            continue
        result.append(path)
    return sorted(result)


def lint_lua_compat(root: Path, path: Path, original: str, masked: str, starts: Sequence[int], ignored: set[str], issues: list[Issue]) -> None:
    checks = [
        (r"//|<<|>>", "error", "lua52-operator", "Lua 5.3+ operators such as //, <<, and >> are not valid in Factorio Lua 5.2."),
        (r"(?<![<>=~])&(?!&)|(?<!\|)\|(?!\|)|(?<![~])~(?![=])", "error", "lua52-bitwise-operator", "Lua 5.3 bitwise operators are not valid in Factorio Lua 5.2."),
        (r"\b0b[01]+\b", "error", "lua52-binary-literal", "Binary integer literals are not valid in Lua 5.2."),
        (r"(?m)^\s*continue\s*(?:;|$)", "error", "lua-no-continue", "Lua has no `continue` statement; use a goto label such as `goto continue` and `::continue::`."),
        (r"!=|&&|\|\||(?<![<>=~])!(?!=)|\+\+", "error", "lua-foreign-operator", "This looks like a JavaScript/C-style operator, not Lua syntax."),
        (r"\b(?:loadfile|dofile)\s*\(", "error", "factorio-unavailable-function", "Factorio does not expose loadfile() or dofile()."),
        (r"\b(?:io|os|coroutine)\s*\.", "error", "factorio-unavailable-library", "Factorio does not expose the io, os, or coroutine libraries."),
        (r"\bdebug\s*\.\s*(?!getinfo\b|traceback\b)[A-Za-z_][A-Za-z0-9_]*", "warning", "factorio-restricted-debug", "Only debug.getinfo() and debug.traceback() are available by default in Factorio."),
        (r"\bmath\s*\.\s*randomseed\s*\(", "warning", "factorio-randomseed-noop", "math.randomseed() has no effect in Factorio; use LuaRandomGenerator when custom RNG state matters."),
        (r"\bmodule\s*\(", "warning", "lua52-module-function", "Lua 5.2 removed the old module() pattern; return a module table instead."),
    ]
    for pattern, severity, rule, message in checks:
        for match in re.finditer(pattern, masked):
            add_issue(issues, ignored, root, path, severity, rule, message, index=match.start(), starts=starts)


def iter_require_calls(original: str, masked: str) -> Iterator[tuple[int, str | None]]:
    for match in re.finditer(r"\brequire\b", masked):
        i = match.end()
        while i < len(original) and original[i].isspace():
            i += 1
        if i < len(original) and original[i] == "(":
            i += 1
            while i < len(original) and original[i].isspace():
                i += 1
        parsed = parse_short_string(original, i)
        if parsed:
            value, _end = parsed
            yield match.start(), value
        else:
            yield match.start(), None


def resolve_require(root: Path, require_name: str) -> list[Path]:
    if require_name.endswith(".lua"):
        raw = require_name[:-4]
    else:
        raw = require_name
    candidates = {
        root / (raw.replace(".", "/") + ".lua"),
        root / (raw.replace("\\", "/").replace("/", os.sep) + ".lua"),
    }
    return sorted(candidates)


def lint_requires(root: Path, path: Path, original: str, masked: str, starts: Sequence[int], ignored: set[str], issues: list[Issue]) -> None:
    for index, require_name in iter_require_calls(original, masked):
        if require_name is None:
            add_issue(issues, ignored, root, path, "warning", "require-dynamic", "Dynamic require() calls are fragile in Factorio; prefer literal module paths.", index=index, starts=starts)
            continue
        if ".." in require_name:
            add_issue(issues, ignored, root, path, "error", "require-parent-path", "Factorio require() does not allow `..` path traversal.", index=index, starts=starts)
        if require_name.endswith(".lua"):
            add_issue(issues, ignored, root, path, "warning", "require-lua-extension", "Use require paths without the .lua extension.", index=index, starts=starts)
        if require_name.startswith("__"):
            if not re.match(r"^__[^/\\]+__\.", require_name):
                add_issue(issues, ignored, root, path, "warning", "require-external-format", "External mod require paths should look like __mod-name__.path.", index=index, starts=starts)
            continue
        if require_name in CORE_LUALIB_REQUIRES:
            continue
        candidates = resolve_require(root, require_name)
        if not any(candidate.exists() for candidate in candidates):
            severity = "warning" if ("." in require_name or "/" in require_name or "\\" in require_name) else "info"
            add_issue(issues, ignored, root, path, severity, "require-unresolved", f"Could not resolve local require `{require_name}` from mod root.", index=index, starts=starts)


def lint_stage_globals(root: Path, path: Path, masked: str, starts: Sequence[int], ignored: set[str], issues: list[Issue]) -> None:
    rel = path.relative_to(root).as_posix().lower()
    name = path.name.lower()
    if name in SETTINGS_STAGE_FILES or name in DATA_STAGE_FILES:
        for global_name in RUNTIME_GLOBALS:
            match = re.search(rf"\b{re.escape(global_name)}\s*(?:\.|:|\[)", masked)
            if match:
                add_issue(issues, ignored, root, path, "error", "stage-runtime-global", f"`{global_name}` is a runtime global and is not available in root settings/data stage files.", index=match.start(), starts=starts)
    if name == "control.lua":
        match = re.search(r"\bdata\s*(?:\.|:|\[)", masked)
        if match:
            add_issue(issues, ignored, root, path, "error", "stage-data-global-in-control", "`data` is only available in the prototype stage, not control.lua.", index=match.start(), starts=starts)
    if rel.startswith("migrations/") and re.search(r"\bdata\s*(?:\.|:|\[)", masked):
        match = re.search(r"\bdata\s*(?:\.|:|\[)", masked)
        if match:
            add_issue(issues, ignored, root, path, "error", "stage-data-global-in-migration", "`data` is not available in Lua migrations.", index=match.start(), starts=starts)


def lint_on_load(root: Path, path: Path, masked: str, starts: Sequence[int], ignored: set[str], issues: list[Issue]) -> None:
    for _call_start, open_paren in iter_call_open_parens(masked, "script.on_load"):
        args, _close = split_call_args(masked, open_paren)
        if not args:
            continue
        function_index = arg_starts_with_function(masked, args[0])
        if function_index is None:
            continue
        body_end = find_matching_function_end(masked, function_index, args[0][1])
        if body_end is None:
            continue
        body = masked[function_index:body_end]
        storage_write = re.search(r"\bstorage\b(?:(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)|(?:\s*\[[^\]]*\]))*\s*=(?!=)|\btable\s*\.\s*(?:insert|remove|sort)\s*\(\s*storage\b", body)
        if storage_write:
            add_issue(issues, ignored, root, path, "error", "on-load-storage-write", "Do not write to storage during script.on_load(); Factorio rejects this to prevent desyncs.", index=function_index + storage_write.start(), starts=starts)
        game_access = re.search(r"\bgame\s*(?:\.|:|\[)", body)
        if game_access:
            add_issue(issues, ignored, root, path, "error", "on-load-game-access", "`game` is not available during script.on_load().", index=function_index + game_access.start(), starts=starts)
        rendering_access = re.search(r"\brendering\s*(?:\.|:|\[)", body)
        if rendering_access:
            add_issue(issues, ignored, root, path, "error", "on-load-rendering-access", "`rendering` is not available during script.on_load().", index=function_index + rendering_access.start(), starts=starts)


def lint_event_registration(root: Path, path: Path, original: str, masked: str, starts: Sequence[int], ignored: set[str], issues: list[Issue], seen_events: dict[str, Issue], seen_nth: dict[str, Issue]) -> None:
    for _call_start, open_paren in iter_call_open_parens(masked, "script.on_event"):
        args, _close = split_call_args(masked, open_paren)
        if not args:
            continue
        first_original = original[args[0][0] : args[0][1]]
        first_masked = masked[args[0][0] : args[0][1]]
        events = extract_event_names(first_original, first_masked)
        if is_table_constructor(first_masked) and len(args) >= 3 and strip_span_text(masked, args[2]) not in {"", "nil"}:
            add_issue(issues, ignored, root, path, "error", "event-filter-array", "script.on_event filters can only be used when registering a single event, not an event array.", index=args[2][0], starts=starts)
        for event_name in events:
            existing = seen_events.get(event_name)
            if existing:
                add_issue(issues, ignored, root, path, "warning", "event-duplicate-registration", f"`{event_name}` is already registered at {existing.path}:{existing.line}; later registrations overwrite earlier handlers.", index=args[0][0], starts=starts)
            else:
                line, col = line_col(starts, args[0][0])
                seen_events[event_name] = Issue(rel_path(path, root), line, col, "info", "event-registration", event_name)
        if len(args) >= 2:
            handler_function = arg_starts_with_function(masked, args[1])
            if handler_function is not None:
                body_end = find_matching_function_end(masked, handler_function, args[1][1])
                if body_end:
                    body = masked[handler_function:body_end]
                    require_match = re.search(r"\brequire\b", body)
                    if require_match:
                        add_issue(issues, ignored, root, path, "error", "require-in-event-handler", "Factorio does not allow require() inside event listeners.", index=handler_function + require_match.start(), starts=starts)
                    metatable_match = re.search(r"\bscript\s*\.\s*register_metatable\s*\(", body)
                    if metatable_match:
                        add_issue(issues, ignored, root, path, "error", "metatable-register-in-event-handler", "script.register_metatable() must be called from root scope, not an event listener.", index=handler_function + metatable_match.start(), starts=starts)

    for _call_start, open_paren in iter_call_open_parens(masked, "script.on_nth_tick"):
        args, _close = split_call_args(masked, open_paren)
        if not args:
            continue
        ticks = extract_event_names(original[args[0][0] : args[0][1]], masked[args[0][0] : args[0][1]])
        for tick in ticks:
            existing = seen_nth.get(tick)
            if existing:
                add_issue(issues, ignored, root, path, "warning", "nth-tick-duplicate-registration", f"`script.on_nth_tick({tick})` is already registered at {existing.path}:{existing.line}; later registrations overwrite earlier handlers.", index=args[0][0], starts=starts)
            else:
                line, col = line_col(starts, args[0][0])
                seen_nth[tick] = Issue(rel_path(path, root), line, col, "info", "nth-registration", tick)


def lint_remote_require(root: Path, path: Path, masked: str, starts: Sequence[int], ignored: set[str], issues: list[Issue]) -> None:
    for _call_start, open_paren in iter_call_open_parens(masked, "remote.add_interface"):
        _args, close = split_call_args(masked, open_paren)
        if close is None:
            continue
        body = masked[open_paren:close]
        require_match = re.search(r"\brequire\b", body)
        if require_match:
            add_issue(issues, ignored, root, path, "error", "require-in-remote-interface", "Factorio does not allow require() during remote.call(); keep remote interface functions free of require().", index=open_paren + require_match.start(), starts=starts)


def find_lua52_checker(user_luac: str | None, disabled: bool) -> tuple[str | None, str | None, str]:
    if disabled:
        return None, None, "disabled"
    candidates: list[tuple[str, str]] = []
    if user_luac:
        candidates.append((user_luac, "luac"))
    else:
        candidates.extend((name, "luac") for name in ("luac5.2", "luac52"))
        candidates.extend((name, "lua") for name in ("lua5.2", "lua52"))

    for candidate, kind in candidates:
        resolved = shutil.which(candidate) or (candidate if Path(candidate).exists() else None)
        if not resolved:
            continue
        try:
            result = subprocess.run([resolved, "-v"], text=True, capture_output=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            continue
        version_text = (result.stdout + result.stderr).strip()
        if "Lua 5.2" in version_text:
            return resolved, kind, version_text
    return None, None, "Lua 5.2 checker not found"


def run_lua_syntax(root: Path, lua_files: Sequence[Path], checker: str | None, checker_kind: str | None, checker_note: str, ignored: set[str], issues: list[Issue]) -> None:
    if not checker or not checker_kind:
        add_issue(issues, ignored, root, root, "info", "lua52-syntax-not-run", f"Lua syntax check skipped: {checker_note}. Install luac5.2/lua5.2 or pass --luac.")
        return
    for path in lua_files:
        if checker_kind == "luac":
            command = [checker, "-p", str(path)]
        else:
            command = [checker, "-e", "local f, err = loadfile(arg[1]); if not f then error(err, 0) end", str(path)]
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=10)
        except (OSError, subprocess.SubprocessError) as exc:
            add_issue(issues, ignored, root, path, "warning", "lua52-syntax-check-failed", f"Could not run Lua syntax checker: {exc}.")
            continue
        if result.returncode == 0:
            continue
        output = (result.stderr or result.stdout).strip()
        match = re.search(r":(\d+):\s*(.*)", output)
        if match:
            add_issue(issues, ignored, root, path, "error", "lua52-syntax", match.group(2), line=int(match.group(1)), col=1)
        else:
            add_issue(issues, ignored, root, path, "error", "lua52-syntax", output or "Lua syntax checker failed.")


def lint_lua_files(root: Path, lua_files: Sequence[Path], ignored: set[str], issues: list[Issue]) -> None:
    seen_events: dict[str, Issue] = {}
    seen_nth: dict[str, Issue] = {}
    for path in lua_files:
        original = read_text(path)
        starts = line_starts(original)
        masked = mask_lua_source(original)
        lint_lua_compat(root, path, original, masked, starts, ignored, issues)
        lint_requires(root, path, original, masked, starts, ignored, issues)
        lint_stage_globals(root, path, masked, starts, ignored, issues)
        lint_on_load(root, path, masked, starts, ignored, issues)
        lint_event_registration(root, path, original, masked, starts, ignored, issues, seen_events, seen_nth)
        lint_remote_require(root, path, masked, starts, ignored, issues)


def lint_mod(args: argparse.Namespace) -> list[Issue]:
    root = Path(args.mod_path).resolve()
    ignored = set(args.ignore or [])
    issues: list[Issue] = []
    if not root.exists():
        add_issue(issues, ignored, root, root, "error", "mod-path-missing", "Mod path does not exist.")
        return issues
    if not root.is_dir():
        add_issue(issues, ignored, root, root, "error", "mod-path-not-directory", "Mod path must be an unpacked Factorio mod directory.")
        return issues

    lint_info_json(root, ignored, issues)
    lint_root_structure(root, ignored, issues)
    lint_locale_files(root, ignored, issues)
    lua_files = discover_lua_files(root, args.exclude or [])
    lint_lua_files(root, lua_files, ignored, issues)
    checker, checker_kind, checker_note = find_lua52_checker(args.luac, args.no_luac)
    run_lua_syntax(root, lua_files, checker, checker_kind, checker_note, ignored, issues)
    return sorted(issues, key=Issue.sort_key)


def summarize(issues: Sequence[Issue]) -> dict[str, int]:
    return {severity: sum(1 for issue in issues if issue.severity == severity) for severity in ("error", "warning", "info")}


def print_text(issues: Sequence[Issue]) -> None:
    if not issues:
        print("No issues found.")
        return
    for issue in issues:
        print(f"{issue.path}:{issue.line}:{issue.col}: {issue.severity.upper()} {issue.rule}: {issue.message}")
    counts = summarize(issues)
    print(f"\nSummary: {counts['error']} error(s), {counts['warning']} warning(s), {counts['info']} info note(s).")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lint an unpacked Factorio mod for Factorio Lua and lifecycle hazards.")
    parser.add_argument("mod_path", nargs="?", default=".", help="Path to the unpacked Factorio mod directory.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON.")
    parser.add_argument("--fail-on", choices=("error", "warning", "info"), default="error", help="Exit non-zero when this severity or higher is present.")
    parser.add_argument("--ignore", action="append", default=[], metavar="RULE_ID", help="Ignore a rule ID. May be repeated.")
    parser.add_argument("--exclude", action="append", default=[], metavar="DIR", help="Exclude an additional directory name. May be repeated.")
    parser.add_argument("--luac", help="Path to luac5.2 or lua5.2 for syntax checking.")
    parser.add_argument("--no-luac", action="store_true", help="Skip external Lua syntax checking.")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    issues = lint_mod(args)
    if args.json:
        print(json.dumps({"issues": [asdict(issue) for issue in issues], "summary": summarize(issues)}, indent=2))
    else:
        print_text(issues)
    threshold = SEVERITY_RANK[args.fail_on]
    return 1 if any(SEVERITY_RANK[issue.severity] >= threshold for issue in issues) else 0


if __name__ == "__main__":
    raise SystemExit(main())
