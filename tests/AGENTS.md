# tests/ — Test Specs and Mock Patterns

## Purpose

Plain Lua test suites validate runtime and data-stage logic without Factorio, using manual API mocks.

## Ownership

- `runtime_spec.lua` — Event-driven chest/construction Demand discovery, one-time bootstrap, tracked reconciliation, exact quality/count aggregation, largest-network source snapshots, multi-source/multi-ship planning, landing-pad matching, temporary schedules, Shipment lifecycle, migration, and fleet behavior
- `data_stage_spec.lua` — Data-stage prototypes for the chest, item, recipe, shortcut, custom input, and native GUI style system
- `locale_spec.py` — Verifies every literal `il-gui.*` LocalisedString reference has an English locale definition
- `live_headless_smoke.py` — Runs the current mod against a copied real Factorio 2.1 save through the disposable headless wrapper and localhost RCON
- `live_headless_smoke_spec.py` — Pure parser and RCON-command tests for the live runner

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
- Cover deterministic splitting across multiple Shipments and multi-source Pickup Legs, scheduled-planet eligibility, cumulative hub requests, one Demand-owned pad request, partial/failure replanning, legacy active-transfer migration, and Demand `source` tracking (set on dispatch, recomputed on cancel, cleared when all Shipments are terminal).
- Bound every queue/bootstrap/reconciliation step and verify one busy domain cannot block chest demand or Shipment progress.
- Live headless checks must use a disposable save copy and isolated write-data/config/ports through `run-disposable-factorio.sh`; never point diagnostics at a player's original save or attach to an existing Factorio process.
- Prepare strict live fixtures in editor mode, then save and play in normal mode with at least one loading or delivering Shipment. A map-editor-only save may have no player force and cannot prove bootstrap or Shipment maintenance. `--allow-no-active` is only a load/tick/API smoke check.
- `--prepare-baseline` must remain a strict regression mode: pause the copied game, enable the hidden setting through the mod-owned remote interface, clear baselines only on existing active Shipments, verify `nil` before advancing, and require a numeric baseline afterward. It must never synthesize or reanimate a Shipment.

## Verification

```
lua tests/runtime_spec.lua
lua tests/data_stage_spec.lua
python tests/locale_spec.py
python tests/live_headless_smoke_spec.py
```

## Child DOX Index

No children.
