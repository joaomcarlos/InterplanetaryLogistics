# tests/ — Test Specs and Mock Patterns

## Purpose

Plain Lua test suites validate runtime and data-stage logic without Factorio, using manual API mocks.

## Ownership

- `runtime_spec.lua` — Event-driven chest/construction Demand discovery, one-time bootstrap, tracked reconciliation, exact quality/count aggregation, largest-network source snapshots, multi-source/multi-ship planning, landing-pad matching, temporary schedules, Shipment lifecycle, migration, and fleet behavior
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
- Prove requester-chest filter events create/update Demands independently of bootstrap, construction, reconciliation, and GUI work.
- Cover one-time bootstrap completion plus event-driven ghost/proxy add, remove, revive, network reassociation, exact quality/count, and tracked reconciliation.
- Source tests read Factorio-maintained logistic-network arrays, select the largest exact-quality network per planet, prefer full then best partial stock, and assert no silo/provider/reserve/reservation gate remains.
- Cover deterministic splitting across multiple Shipments and multi-source Pickup Legs, scheduled-planet eligibility, cumulative hub requests, one Demand-owned pad request, partial/failure replanning, and legacy active-transfer migration.
- Bound every queue/bootstrap/reconciliation step and verify one busy domain cannot block chest demand or Shipment progress.

## Verification

```
lua tests/runtime_spec.lua
lua tests/data_stage_spec.lua
python tests/locale_spec.py
```

## Child DOX Index

No children.
