# tests/ — Test Specs and Mock Patterns

## Purpose

Plain Lua test suites validate runtime and data-stage logic without Factorio, using manual API mocks.

## Ownership

- `runtime_spec.lua` — Demand scanning, construction alert normalization, chest allocation, commandeering, ready conditions, ETA/pinning, reservations, and transfer lifecycle
- `data_stage_spec.lua` — Data-stage prototypes for the chest, item, recipe, shortcut, custom input, and native GUI style system
- `locale_spec.py` — Verifies every literal `il-gui.*` LocalisedString reference has an English locale definition

## Local Contracts

- Each test resets `package.loaded` entries for `scripts.*` and creates fresh `storage`, `settings`, `defines`, and `game` globals.
- Mocks stay inline and cover only the API surface exercised.
- `assert_equal(actual, expected, message)` is the primary assertion helper.
- Tests run sequentially and print `<spec>: OK` on success.

## Work Guidance

- Add a test for each runtime behavior or bug fix.
- Keep tests independent and append each test call at the bottom.

## Verification

```
lua tests/runtime_spec.lua
lua tests/data_stage_spec.lua
python tests/locale_spec.py
```

## Child DOX Index

No children.
