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
- `gui.lua` — High-volume dashboard with Fleet Monitor first; native navigation views for Fleet, Requests, Destinations, and History; Requests includes a fixed detail panel; one scroll owner per visible list

## Work Guidance

- Fleet Monitor must remain the first dashboard view. Automatic/manual refreshes update existing elements in place and must not replace the frame, reset navigation or request selection, or move scroll position.
- Never nest vertical scroll panes. Keep summaries and column headers outside the single list scroll pane for each visible view.
- Do not use nested tabbed panes for dashboard navigation. Native button navigation keeps the layout tree shallow and avoids the engine sizing recursion observed in `TabbedPane::setSize`.
- Every custom GUI style must specify a `parent` to inherit proper default sizing from Factorio's base styles.
- Treat cohesive native styles, visual hierarchy, consistent spacing, readable density, interaction states, tooltips, empty states, and responsive sizing as required implementation work, not optional follow-up polish.
- Use native utility sprites for 32 x 32 row actions and preserve rectangular buttons for text-heavy primary actions. Apply consistent blue, green, orange, red, and muted text colors to statuses, ETAs, metrics, and selected request context.
- Centralize width budgets in `layout()` so the navigation rail, list columns, scroll bar, and request detail panel always fit inside the frame at supported UI scales.
- Delivery Fleet and Other Platforms are separate sections sorted by platform name. Requests are ordered by priority, workflow state, then id; selecting a request preserves its detail panel context.
- Request route cells show `Routing...` until `request.source` resolves; never show the demand origin as a planet.
- Enrollment clicks update controls in place so dashboard navigation and scroll position remain stable.
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
