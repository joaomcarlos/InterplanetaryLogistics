# tests/ — Test Specs and Mock Patterns

## Purpose

Plain Lua test suites that validate runtime and data-stage logic without a Factorio instance. Run under Lua 5.1+ with manual mocks for Factorio globals.

## Ownership

- `runtime_spec.lua` — Tests for demand scanning, construction alert normalization, chest shortage allocation, platform commandeering, transfer lifecycle
- `data_stage_spec.lua` — Tests for `data.lua` prototype extension (chest, item, recipe, shortcut, custom-input)

## Local Contracts

- Each test function calls `reset_modules()` to clear `package.loaded` for `scripts.*` entries, then sets up fresh `storage`, `settings`, `defines`, `game` globals
- Mocks are built inline per test — no shared mock framework
- `assert_equal(actual, expected, message)` is the primary assertion helper
- Tests run sequentially at file bottom; success prints `<spec>: OK`

## Work Guidance

- Add a new test function for each new runtime behavior or bug fix
- Mock only the Factorio API surface the test exercises
- Keep tests independent — each must pass in isolation
- Append the test call at the bottom of the file

## Verification

```
lua tests/runtime_spec.lua
lua tests/data_stage_spec.lua
```

## Child DOX Index

No children.
