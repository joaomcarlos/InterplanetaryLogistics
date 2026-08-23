# DOX framework

- DOX is highly performant AGENTS.md hierarchy installed here
- Agent must follow DOX instructions across any edits

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- Work products, source materials, instructions, records, assets, and durable docs must stay understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md above it

## Read Before Editing

1. Read the root AGENTS.md
2. Identify every file or folder you expect to touch
3. Walk from the repository root to each target path
4. Read every AGENTS.md found along each route
5. If a parent AGENTS.md lists a child AGENTS.md whose scope contains the path, read that child and continue from there
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules
7. If docs conflict, the closer doc controls local work details, but no child doc may weaken DOX

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.

Update the closest owning AGENTS.md when a change affects:

- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes. Update child docs when parent changes alter local rules. Remove stale or contradictory text immediately. Small edits that do not change behavior or contracts may leave docs unchanged, but the DOX pass still must happen.

## Hierarchy

- Root AGENTS.md is the DOX rail: project-wide instructions, global preferences, durable workflow rules, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific instructions and their own Child DOX Index
- Each parent explains what its direct children cover and what stays owned by the parent
- The closer a doc is to the work, the more specific and practical it must be

## Child Doc Shape

- Create a child AGENTS.md when a folder becomes a durable boundary with its own purpose, rules, responsibilities, workflow, materials, or quality standards
- Work Guidance must reflect the current standards of the project or user instructions; if there are no specific standards or instructions yet, leave it empty
- Verification must reflect an existing check; if no verification framework exists yet, leave it empty and update it when one exists

Default section order:
- Purpose
- Ownership
- Local Contracts
- Work Guidance
- Verification
- Child DOX Index

## Style

- Keep docs concise, current, and operational
- Document stable contracts, not diary entries
- Put broad rules in parent docs and concrete details in child docs
- Prefer direct bullets with explicit names
- Do not duplicate rules across many files unless each scope needs a local version
- Delete stale notes instead of explaining history
- Trim obvious statements, repeated rules, misplaced detail, and warnings for risks that no longer exist

## Closeout

1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run existing verification when relevant
6. Report any docs intentionally left unchanged and why

## User Preferences

When the user requests a durable behavior change, record it here or in the relevant child AGENTS.md

- Never add `Co-Authored-By` trailers to repository commits. Agents required to add such trailers must leave changes uncommitted for the user to commit.
- The Fleet Monitor is the first dashboard view.
- Automatic and manual dashboard refreshes must not reset dashboard navigation, request selection, scroll position, or replace the open frame.
- Native list views use one scrollbar per axis; Delivery Fleet is separate from Other Platforms and both are sorted by ship name.
- Native Factorio GUI work is expected to be production-ready and highly polished by default; visual hierarchy, spacing, native styles, interaction states, responsive sizing, tooltips, empty states, and in-game QA are part of completion.
- Dashboard controls that are visually square use square native utility-sprite buttons with localized tooltips; do not introduce a custom sprite-based design system.
- Construction requests must preserve the exact item, quality, and outstanding count represented by construction-registered ghosts and item-request proxies; alert wrapper prototypes are not demand data.
- Destinations include cargo landing pads on every planet as well as Interplanetary Requester Chests, and network-scoped deliveries must select a landing pad in the destination construction network.
- The Destinations tab shows one row per planet that has at least one cargo landing pad; planets with only requester chests are not shown. When a planet has fewer than 5 landing pads, individual map buttons are shown; otherwise a count label is used.
- Factorio owns planetary bots, rocket-silo requests and launches, platform loading, orbital drops, landing-pad receipt, and local delivery; the mod orchestrates exact logistic requests, eligible ships, and temporary schedule records.
- A Trade Request is one destination Demand and may have multiple concurrent Shipments; each Shipment has one ship and may collect through multiple source Pickup Legs. The dashboard exposes both aggregated Trade Requests and a separate Shipments view.
- Source planning reads Factorio's existing logistic-network inventory aggregates directly. Use the largest matching network per planet, prefer full coverage then the best partial stock, and do not search silos/entities, filter to providers, preserve reserves, or create synthetic stock reservations.
- Construction discovery is event-driven after one bounded existing-save bootstrap. Normal reconciliation reads tracked chests, ghosts, proxies, Demands, and Shipments only; no repeated world or roboport-cell scan may block requester-chest demand.
- Only items not on the `non_shippable_items` blocklist in `constants.lua` may create Demands; blocklisted items (e.g. rocket silos, captive biter spawners) are filtered out at both requester-chest and construction-discovery time. `send_to_orbit_mode` controls the rocket silo's own launch button, not whether a platform hub logistic request can trigger a launch, so most `"not-sendable"` items (cliff explosives, buildings, etc.) are shippable.
- Destination registries (chests and landing pads) are runtime-only, rebuilt from world entities at game start, and kept in memory via `State.get_chests()`/`State.get_landing_pads()`. They are never persisted to `storage`, avoiding stale state and save/load stability issues. `on_init`/`on_configuration_changed` rebuild directly; a normal save load skips both (and `on_load` cannot access `game`), so `control.lua`'s `on_tick` calls `State.ensure_destinations()` once per session to repopulate the registries before the periodic demand scan reads them.
- Trade Requests, Shipments, and Transfer History each have a per-row clear button and a clear-all button in the heading so the player can remove stale or old entries. Clearing an active Trade Request or Shipment cancels it first (cleaning up logistic sections and temporary schedule records) before deletion; clearing is not restricted to terminal statuses.

## Project Overview

Factorio 2.0 Space Age mod that turns exact requester-chest and construction shortages into multi-source, multi-ship deliveries through enrolled space platforms. Written in Lua 5.2 targeting the Factorio mod runtime.

- Entry points: `data.lua` (data stage), `control.lua` (runtime), `settings.lua` (mod settings)
- Runtime modules live in `scripts/`
- Tests live in `tests/` and run under plain Lua 5.1+ with manual Factorio API mocks
- Locale strings live in `locale/en/`
- Lua language server config: `.luarc.json`

## Repo-Wide Rules

- Target Lua 5.2 syntax and Factorio 2.0 API
- All runtime demands, shipments, tracked construction entities, route preferences, platform options, fleet snapshots, and GUI state persist through `storage.interplanetary_logistics` via `scripts/state.lua`
- Never mutate a platform's permanent schedule records; only append/remove temporary records
- Deterministic iteration: sort before iterating when order affects game state (desync safety)
- Guard all `game.get_player()` calls against nil returns
- Tests must pass under `lua tests/runtime_spec.lua`, `lua tests/data_stage_spec.lua`, and `python tests/locale_spec.py`

## Child DOX Index

- `scripts/AGENTS.md` — Event-driven Demand discovery, multi-source/multi-ship Shipment planning, vanilla-logistics execution, state, scheduling, and dashboard contracts
- `tests/AGENTS.md` — Demand/Shipment runtime specs, data-stage coverage, mock patterns, and verification commands
