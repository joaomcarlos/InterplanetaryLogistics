---
name: factorio-mod-lint
description: Lint Factorio mods for Factorio's modified Lua 5.2 runtime, mod folder structure, info.json metadata, locale files, migrations, require paths, lifecycle hazards, storage/global migration issues, duplicate script event registrations, and Lua Language Server compatibility. Use when Codex is reviewing, fixing, or validating a Factorio mod, especially control.lua, data.lua, settings.lua, migrations, locale cfg files, or Factorio load/desync errors.
---

# Factorio Mod Lint

## Overview

Use this skill to lint Factorio mods with checks that understand Factorio's modified Lua 5.2 environment and data/control lifecycle. Prefer the bundled scripts before making code edits, then re-run them after edits.

## Workflow

1. Inspect local project instructions first: `AGENTS.md`, `standard.md`, or repo-specific lint notes.
2. Run the bundled linter from the skill directory:

```bash
python C:/Users/silent/.codex/skills/factorio-mod-lint/scripts/lint_factorio_mod.py <mod-folder>
```

3. Treat `error` findings as likely Factorio load/runtime failures. Treat `warning` findings as high-signal review items that may need local-context judgment. Treat `info` findings as compatibility or ergonomics notes.
4. If the installed Lua compiler is not Lua 5.2, do not use it as proof that a Factorio mod is invalid. Factorio supports Lua 5.2 features such as `goto`; Lua 5.1 `luac` will produce false syntax errors.
5. On Windows, Chocolatey `lua52` is a verified working setup. It exposes `lua52` and `luac52` on `PATH`, and the linter auto-detects those names.
6. After fixing issues, re-run the linter. If behavior depends on a current Factorio API detail, verify against official docs before changing code.

## Scripts

### `scripts/lint_factorio_mod.py`

Run static checks for:

- `info.json` required fields, version format, dependency syntax, and folder-name consistency.
- Recognized Factorio root files and migration file extensions.
- Locale `.cfg` section/key shape and duplicate locale keys.
- Factorio Lua 5.2 incompatibilities such as Lua 5.3 bitwise operators, `//`, `0b...`, `continue`, `!=`, `&&`, `||`, and `++`.
- Factorio sandbox restrictions such as `io`, `os`, `coroutine`, `loadfile`, `dofile`, restricted `debug.*`, and `math.randomseed()`.
- `require()` path hazards, missing local modules, `..` path use, dynamic requires, and requires inside inline event handlers.
- Lifecycle hazards: writes to `storage` or use of `game`/`rendering` inside inline `script.on_load(function() ... end)`.
- Duplicate `script.on_event` and `script.on_nth_tick` registrations that would overwrite earlier handlers.
- Use of runtime globals in root data/settings files, and use of `data` in root `control.lua`.

Useful options:

```bash
python C:/Users/silent/.codex/skills/factorio-mod-lint/scripts/lint_factorio_mod.py . --json
python C:/Users/silent/.codex/skills/factorio-mod-lint/scripts/lint_factorio_mod.py . --fail-on warning
python C:/Users/silent/.codex/skills/factorio-mod-lint/scripts/lint_factorio_mod.py . --ignore RULE_ID
python C:/Users/silent/.codex/skills/factorio-mod-lint/scripts/lint_factorio_mod.py . --luac C:/path/to/luac5.2.exe
```

### `scripts/write_factorio_lua_ls_config.py`

Create or update `.luarc.json` for Lua Language Server compatibility with Factorio Lua:

```bash
python C:/Users/silent/.codex/skills/factorio-mod-lint/scripts/write_factorio_lua_ls_config.py <mod-folder>
```

This sets Lua 5.2 and registers common Factorio globals such as `data`, `mods`, `settings`, `script`, `game`, `storage`, `remote`, `commands`, `rendering`, `prototypes`, `helpers`, `defines`, `serpent`, `log`, `localised_print`, and `table_size`.

## Reference

Read `references/factorio-lint-rules.md` when adding rules, deciding whether a finding is a false positive, or checking the Factorio API basis for an existing rule.
