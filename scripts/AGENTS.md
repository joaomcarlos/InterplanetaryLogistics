# scripts/ — Runtime Module Contracts

## Purpose

All runtime logic for the Interplanetary Logistics mod. Modules are loaded via `require("scripts.<name>")` from `control.lua`.

## Ownership

Each module owns a single responsibility. Cross-module calls flow downward: `control` → `demands` → `router` → `platforms` → `state`/`util`. `gui` reads state but does not mutate request/transfer lifecycle.

## Local Contracts

- `constants.lua` — Central config values: entity names, timeouts, active status set, schema version, history limit
- `state.lua` — All persistent state under `storage.interplanetary_logistics`. `State.ensure()` initializes the schema. `State.rebuild_chests()` rescans surfaces. `State.add_history()` appends capped history entries
- `util.lua` — Pure helpers: deep copy, item ID/signal constructors, surface location resolution, platform lookup, tick formatting, sorted iteration, GPS strings, ghost detection, sprite resolution
- `demands.lua` — Demand scanning (chest shortages + construction alerts), request lifecycle (create/queue/approve/deny/cancel), auto-approve timer, unseen-request retirement
- `router.lua` — Source planet ranking by reliability score + provider stock, platform matching via `Platforms.find_matching`, dispatch delegation
- `platforms.lua` — Platform enrollment, capacity checks, schedule manipulation (temporary record append/remove), request sections on hub and landing pad, transfer monitoring, completion/failure/timeout handling
- `gui.lua` — Dashboard GUI: tabbed pane with compact request-table, chests, platforms, and history tabs. Request-table route cells use planet icons; source is the routed `request.source` or a neutral "Any planet" placeholder, never the demand origin label. Tab selection persistence. No request mutation — only reads state and calls `Demands`/`Platforms` on button clicks

## Work Guidance

- The compact request-table shows `Routing...` in the From cell until `request.source` is resolved; it must never display the demand origin label as a planet.
- Platform enrollment rows are a compact horizontal table. Enrollment clicks update the existing controls in place so the active tabs and scroll position are preserved.
- New modules must be `require`-able from `control.lua` and listed here
- Any new persistent state field must be initialized in `State.ensure()`
- Schedule manipulation must only add/remove records with `temporary = true`
- Iteration over game entities that affects state must be sorted for determinism

## Verification

```
lua tests/runtime_spec.lua
```

## Child DOX Index

No children.
