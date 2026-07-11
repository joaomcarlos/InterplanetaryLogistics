---
name: factorio-performance
description: Diagnose and prevent Factorio mod runtime lag, tick spikes, UPS drops, and stutter in Lua 5.2 control-stage code. Use when reviewing or changing control.lua, runtime modules, event handlers, scanners, GUIs, inventories, entity searches, schedulers, or profiler output for Factorio 2.0/Space Age mods.
---

# Factorio Performance

Profile first, identify the operation that creates the spike, then reduce its frequency, scope, allocation rate, or per-tick budget. Preserve deterministic behavior and gameplay semantics while keeping expensive work out of `on_tick` and large event handlers.

## Workflow

1. Read the repository's `AGENTS.md` chain and runtime entry points.
2. Inspect time-usage output. Separate steady cost from periodic spikes; a low average with a large maximum usually means a full scan, rebuild, log burst, or GUI rebuild.
3. Search for `on_tick`, `on_nth_tick`, `find_entities*`, `get_alerts`, inventory/network queries, `pairs`, `table.sort`, GUI `clear`/`destroy`, and logging in loops.
4. Establish a baseline with the mod's tests and linter. If possible, reproduce in a save and compare current/average/maximum time after each change.
5. Fix the smallest proven hotspot, add a regression test when behavior is testable, and rerun all checks.

## Rules of thumb

- Prefer event-driven updates: maintain registries from build/remove events instead of repeatedly searching every surface.
- Use `script.on_nth_tick` for periodic work. Do not poll a heavyweight operation from `on_tick` unless it is bounded and cheap. Combine schedules so the same operation is not run twice on one tick.
- Never perform an unbounded full-world scan in one tick when the result can be queued. Split work by surface, chunk, entity, player, or request and process a small budget per tick.
- Cache immutable or same-tick query results, especially `find_entities_filtered`, logistic-network lookups, surface lists, and prototype-derived data. Include every changing input in the key and clear caches when the tick or relevant state changes.
- Keep reservations and cached stock separate: cache raw provider counts, then subtract current reservations so multiple requests in one tick remain correct.
- Avoid rebuilding GUIs for live refreshes. Update existing elements in place and refresh only dynamic fields; preserve selected tabs and scroll owners.
- Do not log inside high-volume loops. Make diagnostics opt-in and aggregate counters, or sample only when profiling is enabled.
- Sort only at stable boundaries where deterministic order matters. Avoid repeatedly sorting the same unchanged collection.
- Avoid `table.remove(queue, 1)` for large queues; use a cursor or ring-buffer pattern.
- Keep runtime-only profiling state out of `storage`; make profiler creation opt-in because profiling itself has overhead.
- Validate every Factorio API shape against current official runtime docs. A successful `pcall` does not prove an API operation succeeded.

## Spike patterns and fixes

- Duplicate periodic work: centralize ownership of monitoring and refresh calls.
- Repeated identical queries during one dispatch pass: cache by tick and input key, but layer mutable reservations correctly.
- Full scan at scan time: turn it into a persistent job with a bounded per-tick budget. Keep manual rescans explicit if they cannot be chunked.
- Alert/player duplication: deduplicate at the narrowest safe scope and verify whether alerts are player-specific before reducing coverage.
- Debug output: remove string construction and logging from the normal path; gate it behind a setting or profiler flag.
- GUI spike: update rows/captions in place, throttle refreshes, and rebuild only on structural changes.
- GUI layout recursion crash: setting `vertically_stretchable = true` on a tabbed-pane whose tab content is also `vertically_stretchable` creates a circular layout dependency (the tabbed-pane asks content for preferred height, content defers back to tabbed-pane) causing infinite recursion in Factorio's C++ `TabbedPane::setSize` and a stack overflow crash. `vertically_stretchable` is a valid `StretchRule` property on `TabbedPaneStyleSpecification` (default `"auto"`), but setting it to `"on"` without a height constraint triggers the cycle. The base game uses `maximal_height` or fixed `height` on tabbed panes instead. Custom GUI styles without a `parent` can default to zero size and exacerbate the cycle.

## Scheduler pattern

For expensive work, store a job with a cursor and process a bounded amount each scheduler step:

```lua
local job = {items = items, index = 1}

local function step_job(budget)
  local processed = 0
  while processed < budget and job and job.index <= #job.items do
    process(job.items[job.index])
    job.index = job.index + 1
    processed = processed + 1
  end
  if job and job.index > #job.items then job = nil end
end
```

Use separate queues per surface or domain when possible. Cap both scan work and downstream actions. Do not let a new scan restart or duplicate an active job.

## Lessons from existing mods

When AutoModuleUpgrade is available locally, inspect its scan scheduler and runtime profiling controls. Its useful patterns are per-surface queues, a small entities-per-step budget, deferred replacement checks, scan deduplication, and profiling disabled in normal play.

Treat other mods such as LilEinstein as implementation references only after inspecting their actual source and Factorio version. Transfer patterns, not assumptions: measure the target mod and preserve its API and gameplay contracts.

## Verification

- Run the repository's Lua/data/locale tests and Factorio-aware linter.
- Review the diff for duplicate event registrations, storage lifecycle mistakes, nondeterministic state changes, and stale caches.
- If a Factorio save is available, capture the same time-usage view before and after the change, including maximum time over a long enough interval to include the periodic job.

## References

- [Factorio LuaBootstrap runtime docs](https://lua-api.factorio.com/latest/classes/LuaBootstrap.html) for `on_nth_tick` and event registration.
- [Factorio LuaSurface runtime docs](https://lua-api.factorio.com/latest/classes/LuaSurface.html) for entity-search APIs.
- [Factorio EventFilter docs](https://lua-api.factorio.com/latest/concepts/EventFilter.html) for filtering irrelevant callbacks in the engine.
