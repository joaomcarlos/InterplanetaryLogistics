# Factorio Lint Rule Notes

Use this reference when interpreting or extending `scripts/lint_factorio_mod.py`.

## API Basis

- Factorio mods use a modified Lua 5.2.1 runtime. Do not validate Factorio code with Lua 5.1 tools unless the result is treated as advisory only.
- Factorio's mod structure centers on `info.json`, optional root stage files (`settings*.lua`, `data*.lua`, `control.lua`), `locale`, and `migrations`.
- Factorio's Lua environment removes or replaces standard modules for determinism: `loadfile`, `dofile`, `coroutine`, `io`, and `os` are inaccessible; `package` and `debug` are Factorio-specific.
- `require()` starts at the mod root for absolute paths, cannot use `..`, can require from `__other-mod__.path`, and cannot be used inside event listeners or `remote.call()`.
- Runtime `storage` replaced pre-2.0 `global`. `storage` is not restored during the initial `control.lua` load and cannot be written during `on_load`.
- `script.on_load` cannot access `game`; legitimate work is limited to restoring local state, metatables, and conditional event registrations.
- Each mod can register only one handler per event. A later `script.on_event` for the same event overwrites the earlier handler, even with different filters.

Primary docs:

- https://lua-api.factorio.com/latest/
- https://lua-api.factorio.com/latest/auxiliary/libraries.html
- https://lua-api.factorio.com/latest/auxiliary/mod-structure.html
- https://lua-api.factorio.com/latest/auxiliary/data-lifecycle.html
- https://lua-api.factorio.com/latest/auxiliary/storage.html
- https://lua-api.factorio.com/latest/classes/LuaBootstrap.html

## Rule Severity

- Use `error` for likely load errors, runtime errors, desync hazards, or overwrite behavior documented by Factorio.
- Use `warning` for strong compatibility signals that may need context, such as unresolved local `require()` paths.
- Use `info` for environment notes and optional cleanup, such as missing Lua 5.2 syntax checking.

## False Positive Policy

Keep checks conservative. Do not add broad "undeclared global" or "top-level game access" rules unless the script can distinguish Factorio lifecycle code from module declarations well enough to avoid routine false positives.

When a warning is intentionally acceptable for a project, use `--ignore RULE_ID` in the run command rather than weakening the rule globally.
