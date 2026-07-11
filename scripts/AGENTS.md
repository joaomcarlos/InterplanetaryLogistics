# scripts/ — Runtime Module Contracts

## Purpose

All runtime logic for the Interplanetary Logistics mod. Modules are loaded via `require("scripts.<name>")` from `control.lua`.

## Ownership

Each module owns a single responsibility. Cross-module calls flow downward: `control` → `demands` → `router` → `platforms` → `state`/`util`. `gui` reads state and calls public demand/platform actions from GUI events.

## Local Contracts

- `constants.lua` — Entity names, scan/monitor/ETA timeouts, active statuses, schema version, and history limit
- `state.lua` — Persistent requests, reservations, route preferences, platform options, fleet snapshots, return cargo, GUI state, history, and schema migration
- `util.lua` — Pure item, signal, surface, route, platform, formatting, sorting, GPS, ghost, and sprite helpers
- `demands.lua` — Shortage scanning, request lifecycle, priority, approval, suppression, and retirement
- `router.lua` — Reservation-aware source ranking, ETA/pin-aware platform matching, and dispatch delegation
- `platforms.lua` — Enrollment, ETA/status/stuck monitoring, route pinning, ready signals, temporary schedules, request sections, return cargo, and transfer lifecycle
- `gui.lua` — High-volume dashboard with Fleet Monitor first; Delivery Fleet/Other Platforms and Active/Needs Attention subviews; Destinations and History; one scroll owner per leaf list

## Work Guidance

- Fleet Monitor must remain the first main tab. Automatic/manual refreshes update existing elements in place and must not replace the frame, reset tabs, or move scroll position.
- Never nest vertical scroll panes. Keep summaries and column headers outside the single leaf-list scroll pane.
- All tabbed panes must use a fixed `height` or `maximal_height` constraint, not `vertically_stretchable = true`. Setting `vertically_stretchable` to `"on"` when tab content is also stretchable creates a circular layout dependency in `TabbedPane::setSize` that crashes the game with a stack overflow.
- Every custom GUI style must specify a `parent` to inherit proper default sizing from Factorio's base styles.
- Treat cohesive native styles, visual hierarchy, consistent spacing, readable density, interaction states, tooltips, empty states, and responsive sizing as required implementation work, not optional follow-up polish.
- Delivery Fleet and Other Platforms are separate views sorted by platform name. Requests are ordered by priority, workflow state, then id.
- Request route cells show `Routing...` until `request.source` resolves; never show the demand origin as a planet.
- Enrollment clicks update controls in place so the active tabs and scroll position remain stable.
- Every player-facing GUI caption and tooltip uses a defined `il-gui.*` LocalisedString; validate with `python tests/locale_spec.py`.
- Dispatch order is deterministic: priority, creation tick, then request id.
- Initialize every persistent field in `State.ensure()`.
- Only add or remove schedule records with `temporary = true`; never mutate permanent records.
- Sort iteration that affects game state.
- Keep periodic monitoring single-owned: `Platforms.monitor()` runs from the control scheduler, not from both scan processing and the monitor interval.
- Keep expensive provider/network queries cached for the current tick when multiple requests share the lookup; subtract live reservations after reading cached stock.
- Keep normal alert scanning silent; diagnostics must not build log strings inside high-volume loops.
- Periodic and manual scans use `Demands.start_scan()` plus bounded `Demands.step_scan()` work; do not reintroduce a full scan in `on_tick` or GUI events.
- Scan completion must start `Demands.start_process()`; approval and dispatch work advances through `Demands.step_process()` and must not sort/dispatch the entire request table in one tick.
- Keep monitor, fleet snapshots, and GUI refreshes on separate tick offsets so maintenance work does not stack with scan or dispatch work.
- Maintenance work is single-lane and resumable: monitor active transfers, fleet snapshots, and open-GUI refreshes must advance through their bounded step APIs; never run two maintenance jobs or rebuild an entire maintenance collection in the tick loop.

## Verification

```
lua tests/runtime_spec.lua
```

## Child DOX Index

No children.
