# UPS-safe state and background work

## Contents

- Core contract
- Event-driven indexes
- Deterministic work queues
- Scheduling
- GUI-specific costs
- Persistent state lifecycle
- Profiling and verification
- Anti-patterns

## Core contract

Treat UPS as a functional requirement. Every recurring operation must have a known trigger, frequency, candidate count, and worst-case work per tick.

Apply these rules to the entire mod, including scanners, routing, logistics, migrations, caches, and GUI support—not just visible interface code.

## Event-driven indexes

Prefer maintaining small indexes from events over rediscovering the world:

- Register relevant entities on build/revive/clone events.
- Remove them on mine/destroy/death events.
- Rebuild indexes on initialization and configuration change.
- Validate indexed objects lazily and remove stale entries.
- Cache stable prototype-derived data after initialization.
- Use dirty flags when source state changes; do no work when nothing is dirty.

Do not call broad `find_entities_filtered`, scan every surface, iterate every player, or traverse all persistent records every tick unless the bounded population is demonstrably tiny.

## Deterministic work queues

Spread unavoidable heavy work across ticks with a deterministic count budget:

```lua
local budget = 50
while budget > 0 and state.scan_cursor <= #state.scan_jobs do
  process(state.scan_jobs[state.scan_cursor])
  state.scan_cursor = state.scan_cursor + 1
  budget = budget - 1
end
```

- Persist queue data and cursors when work must survive save/load.
- Sort jobs by stable IDs before processing when order can affect game state.
- Use fixed item/count budgets, never elapsed wall-clock time, to decide synchronized work; time-based branching can desynchronize multiplayer.
- Compact completed queues without repeated `table.remove(list, 1)` operations.
- Define fairness when multiple forces, surfaces, players, or job classes compete.
- Coalesce duplicate jobs with a keyed dirty set.
- Make jobs idempotent or record completion so retries are safe.
- Bound queue growth and discard stale jobs.

## Scheduling

- Use events for immediate reactions.
- Use `script.on_nth_tick` for periodic reconciliation and choose the slowest acceptable cadence.
- Avoid large modulo dispatch blocks in `on_tick` when separate nth-tick registration is clearer.
- Stagger independent maintenance jobs across different ticks.
- Separate urgent transfer monitoring from slow discovery/reconciliation scans.
- Run expensive migrations in controlled batches when Factorio permits deferred work; keep required configuration-change mutations safe and deterministic.

## GUI-specific costs

- Iterate only connected players with the relevant root frame open.
- Update existing captions, numbers, sprites, visibility, and enabled state in place.
- Refresh dirty components rather than rebuilding a whole dialog.
- Do not rebuild an open root frame periodically.
- Avoid per-tick recursive tree walks; cache ephemeral component references or refresh at a measured low cadence, validating references before use.
- Paginate, filter, virtualize conceptually, or batch-build very large row collections.
- Do not recalculate domain data separately for every viewing player; calculate shared results once and render player-specific presentation afterward.

## Persistent state lifecycle

- Keep all durable data under the mod's storage namespace.
- Initialize every field in one schema entrypoint.
- Version schemas and migrate old saves explicitly.
- Store unit numbers, player indexes, force indexes, and platform/entity IDs rather than Lua objects when persistence is required.
- Remove player UI state on player removal when it is no longer useful.
- Clean invalid entity IDs, expired reservations, completed jobs, and obsolete cache entries.
- Rebuild derived caches instead of migrating them when rebuilding is safer and bounded.
- Never mutate persistent state in `on_load`; only restore local references or registration-safe structures there.

## Profiling and verification

- Use Factorio's profiler and representative large saves to measure hot paths.
- Measure idle cost, ordinary active cost, and worst-case bursts separately.
- Test multiple forces, many surfaces, thousands of indexed entities, several connected players, and large queues.
- Verify the maximum jobs processed per tick matches the configured budget.
- Verify queues resume after save/load and configuration change.
- Verify no work occurs when dirty sets and queues are empty.
- Record expected complexity and cadence near the owning code or contract.

Profiler data is observational. Never use profiler elapsed time to determine synchronized game-state branching or queue cutoffs.

## Anti-patterns

- Whole-world scans on every tick.
- Rebuilding every open GUI on a timer.
- Sorting the same unchanged collection for every player refresh.
- Nested loops over all surfaces, entities, requests, and platforms without a strict bound.
- One queue processed to exhaustion in a single tick.
- Wall-clock or profiler-time work budgets.
- Persistent LuaGuiElement or LuaEntity references.
- Unbounded history, cache, dirty-set, or job growth.
- Debug logging inside large recurring loops.
