# scripts/ — Runtime Module Contracts

## Purpose

All runtime logic for the Interplanetary Logistics mod. Modules are loaded via `require("scripts.<name>")` from `control.lua`.

## Ownership

Each module owns a single responsibility. Calls flow from event-driven demand discovery through multi-ship planning into vanilla-logistics execution: `control` → `demands` → `router` → `platforms` → `state`/`util`. `gui` reads persisted Demands and Shipments and invokes their public actions.

## Local Contracts

- `constants.lua` — Entity names, reconciliation/execution timeouts, bounded-work budgets, active statuses, schema version, history limit, and the `non_shippable_items` blocklist
- `state.lua` — Persistent Demands (including the primary `source` field), Shipments, Demand-owned pad sections, tracked construction entities, dirty queues, bootstrap state, route preferences, platform options, fleet snapshots, return cargo, GUI state, history, and schema migration. Destination registries (chests, landing pads) are runtime-only, not persisted.
- `util.lua` — Pure item, signal, surface, route, platform, destination grouping, formatting, sorting, GPS, ghost, sprite helpers, and blocklist-based `is_shippable`
- `demands.lua` — Event-driven chest/construction discovery, tracked reconciliation, Demand lifecycle, priority, approval, suppression, retirement (cancels child shipments via `Platforms.cancel`), and full `Demands.remove` cleanup (cancels active demand, removes child shipments, drops pad section, clears key/suppression)
- `router.lua` — Largest-network source snapshots, deterministic multi-source/multi-ship planning, schedule eligibility, and Shipment creation
- `platforms.lua` — Enrollment, Shipment execution, platform/landing-pad logistic sections, temporary schedules, event-driven progress, cleanup, return cargo, failure lifecycle, `Platforms.remove_shipment` (cancels active, deletes terminal), and `Platforms.cancel` (cancels child shipments, removes pad section, then marks demand cancelled)
- `scheduler.lua` — Independent bounded dirty queues, tracked reconciliation, Shipment execution (starts and steps planned shipments), Shipment maintenance, fleet snapshots, and GUI refresh scheduling
- `gui.lua` — High-volume dashboard with Fleet Monitor first; native navigation views for Fleet, Trade Requests, Shipments, Destinations, and History; one scroll owner per visible list; per-row and clear-all remove buttons on Trade Requests, Shipments, and History
- `source_stock.lua` — Same-tick exact item/quality aggregate reads from Factorio-maintained logistic-network arrays; no entity or silo discovery

## Work Guidance

- Fleet Monitor must remain the first dashboard view. Automatic/manual refreshes update existing elements in place and must not replace the frame, reset navigation or selection, or move scroll position.
- Native navigation exposes Fleet Monitor, Trade Requests, Shipments, Destinations, and History. Trade Requests aggregate destination Demands and show both Source and Destination columns (Source reads the Demand `source` field, showing "Routing..." before dispatch); Shipments expose individual ship execution and link back to their parent Demand.
- Never nest vertical scroll panes. Keep summaries and column headers outside the single list scroll pane for each visible view.
- Do not use nested tabbed panes for dashboard navigation. Native button navigation keeps the layout tree shallow and avoids the engine sizing recursion observed in `TabbedPane::setSize`.
- Every custom GUI style must specify a `parent` to inherit proper default sizing from Factorio's base styles.
- Treat cohesive native styles, visual hierarchy, consistent spacing, readable density, interaction states, tooltips, empty states, and responsive sizing as required implementation work, not optional follow-up polish.
- Use native utility sprites for 32 x 32 row actions and preserve rectangular buttons for text-heavy primary actions. Apply consistent blue, green, orange, red, and muted text colors to statuses, ETAs, metrics, and selected context.
- Centralize width budgets in `layout()` so the navigation rail, list columns, scroll bar, and detail panels fit inside the frame at supported UI scales.
- Delivery Fleet and Other Platforms are separate sections sorted by platform name. Demands are ordered by priority, workflow state, then id; Shipments use deterministic status and id ordering.
- Enrollment clicks and structural/value refreshes update the smallest existing subtree so dashboard navigation and scroll position remain stable.
- Requester-chest and cargo-landing-pad build/removal events refresh the open Destinations subtree and summary in place. Destination registries are runtime-only locals in `state.lua`, rebuilt from world entities at game start and maintained via events; they are never persisted to `storage`. `on_init`/`on_configuration_changed` rebuild directly; a normal save load skips both and `on_load` cannot access `game`, so `control.lua`'s `on_tick` calls `State.ensure_destinations()` once per session (gated by the `destinations_initialized` local) before the periodic demand scan reads `State.get_chests()`.
- The Destinations view shows one row per planet with at least one cargo landing pad; planets with only requester chests are hidden. Each row shows map buttons for individual pads when fewer than 5, or a count label when 5 or more.
- Every player-facing GUI caption and tooltip uses a defined `il-gui.*` LocalisedString; validate with `python tests/locale_spec.py`.
- A Demand is an exact destination need keyed by origin identity, destination surface/network, item, and quality. It owns observed shortage, active-shipment quantity, unplanned quantity, approval, priority, denial, suppression, and a primary `source` location.
- The Demand `source` field records the first pickup-leg source of the earliest active child Shipment. It is nil ("Routing...") before dispatch, set by `State.create_shipment`, and recomputed on `State.cancel_shipment` / `State.delete_shipment` so it always reflects the current active shipment set. Schema 4 backfills it for existing demands; schema 5 consumes legacy transfer indexes after migration.
- Requester-chest observed shortage subtracts exact-quality chest contents and robot deliveries already targeted to that chest. Construction observed shortage subtracts exact-quality inventory in the tracked construction logistic network.
- A Shipment assigns one enrolled ship to part of one Demand and may contain multiple ordered Pickup Legs. A Demand may own multiple concurrent Shipments.
- Source planning reads exact item/quality counts from `force.logistic_networks` and uses the largest valid network count per planet. Prefer planets covering the full remainder, then the best partial counts.
- Do not search surfaces for rocket silos or source entities, filter source counts to providers, preserve source reserves, or persist synthetic stock reservations. Factorio arbitrates real inventory contention.
- Within one deterministic planning operation, an ephemeral availability copy may prevent one Demand from assigning the same observed units twice; this is not persisted as source state.
- Multiple ships may fulfill one Demand. Each ship may use only source and destination planets present in its permanent schedule, and pickup order follows that schedule from its current position toward the destination.
- Each Pickup Leg writes a planet-scoped platform-hub logistic request with a cumulative cargo target. Only append/remove temporary source and destination records; never mutate permanent records or their ordering.
- One Demand-owned logistic section requests all active Shipment cargo at a landing pad in the destination network. Shipment-owned duplicate pad sections are forbidden.
- Factorio owns bots, rocket-silo requests and launches, platform loading, orbital drops, landing-pad receipt, and local delivery. The mod observes those results and cleans up its request sections and temporary records.
- Construction demand is maintained from construction-registered entity ghosts, tile ghosts, and item-request proxies through build/remove/revive/upgrade events. Preserve exact counts and LuaQualityPrototype names; never infer demand from alert wrapper prototypes. Only items not on the `non_shippable_items` blocklist in `constants.lua` create Demands; blocklisted items are filtered at both chest and construction discovery. `send_to_orbit_mode` is not used for filtering — platform hub logistic requests bypass it.
- A bounded one-time bootstrap may discover existing chests, pads, ghosts, tile ghosts, and proxies after installation or schema migration. Normal operation must never repeat a world or roboport-cell construction scan.
- Immediate event dirty queues for chests, construction entities, and Shipments are independent. Low-priority reconciliation reads registered/tracked objects only and cannot block new requester-chest demand.
- Roboport topology changes re-associate already tracked construction entities; they do not trigger broad surface searches.
- `on_space_platform_changed_state`, `on_cargo_pod_delivered_cargo`, and `on_entity_logistic_slot_changed` drive immediate Shipment progress and destination observation. Bounded tracked reconciliation handles missed inventory/state transitions, with a delivery-confirmation timeout for cargo that never appears at its destination.
- Invalid ships, pads, or schedules fail only the affected Shipment. Short pickup legs continue to later sources; partial delivery returns the remainder to the parent Demand for replanning. Maintenance backfills missing legacy hub baselines from the current observation before doing delivery arithmetic.
- If local logistics fulfill a Demand while cargo is moving, remove its pad request, clean up child Shipments, preserve onboard cargo, and safely restore each ship's permanent schedule position.
- Space-platform cargo storage is the hub's `defines.inventory.hub_main` inventory; do not use `LuaEntity.get_main_inventory()` for platform hubs.
- Quality-aware request icons use `sprite-button.quality`; never assign sprite-only `resize_to_sprite` or `stretch_image_to_widget_size` properties to a sprite button.
- Initialize and migrate every persistent Demand, Shipment, tracked-entity, dirty-queue, bootstrap, fleet, history, and GUI field in `State.ensure()`.
- Sort every iteration that affects game state. Cache same-tick logistic-network aggregates by force, surface, item, and quality.
- Keep fleet snapshots, tracked reconciliation, Shipment maintenance, and open-GUI refreshes bounded and on separate offsets so work does not stack.
- Each history entry carries a monotonic `seq` assigned in `State.add_history`; per-row clear buttons key off `seq` via `State.remove_history_entry(seq)`, and `State.clear_history()` wipes the log. Both refresh via `Gui.refresh_history_structure`.
- Trade Requests, Shipments, and History each expose a per-row red trash button and a heading clear-all button. Clear routes through `Demands.remove` / `Platforms.remove_shipment` / `State.remove_history_entry` / `State.clear_history` so active demands and shipments are cancelled (cleaning hub/pad sections and temporary records) before deletion; terminal rows are deleted directly. Clear-all iterates the player's force rows in sorted id order for desync safety.

## Verification

```
lua tests/runtime_spec.lua
```

## Child DOX Index

No children.
