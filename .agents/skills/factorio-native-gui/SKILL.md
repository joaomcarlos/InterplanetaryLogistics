---
name: factorio-native-gui
description: Build, refactor, review, and validate native Factorio mod GUIs made with LuaGuiElement, Factorio styles, LocalisedString captions, and GUI events, including persistent UI state and UPS-safe runtime support. Use for dashboards, dialogs, tables, tabs, list views, controls, live refresh behavior, state tracking, performance-sensitive scans and queues, accessibility, localization, and Factorio-native visual polish. Do not use for screenshot-replication, baked-background, sliced-sprite, or sprite-composited interfaces; those belong to a Factorio UI mockup workflow.
---

# Factorio Native GUI

## Scope boundary

Use Factorio's native `LuaGuiElement` hierarchy, built-in utility sprites, prototype styles, and LocalisedStrings.

Do not use this skill for sprite-based UI replicas, screenshot slicing, baked panel backgrounds, or LilEinstein-style composited interfaces. Use `factorio-ui-mockup` for those tasks.

## Default quality bar

Deliver a production-ready, exceptionally polished native Factorio interface by default. Do not stop at functional structure or defer visual refinement to a hypothetical later pass. Treat hierarchy, spacing, density, alignment, interaction states, tooltips, empty states, localization, scroll behavior, responsive sizing, accessibility, and in-game verification as part of implementation completeness.

## Workflow

1. Read the repository instructions and the complete GUI/state/event modules before editing.
2. Identify GUI and runtime ownership: build functions, refresh functions, event router, per-player UI state, persistent domain indexes, scan queues, styles, and locale files.
3. Decide which updates are structural and which are value-only.
   - Build or rebuild only when element shape changes.
   - Update captions, tooltips, visibility, enabled state, sprites, numbers, and colors in place.
   - Never periodically destroy and recreate an open frame.
4. Define stable element identities.
   - Use names for unique structural elements.
   - Use `tags` for event action and domain identifiers.
   - Route GUI events centrally and validate `event.element.valid` and `event.player_index`.
5. Preserve player context.
   - Persist selected tabs, filters, sort mode, search text, and dialog mode per player.
   - Read live tab selection before an unavoidable rebuild and restore it afterward.
   - Preserve scroll position by avoiding rebuilds; Factorio does not expose a readable scroll offset.
   - Keep transient rebuild guards from overwriting saved state through programmatic events.
6. Protect UPS across the whole mod path supporting the UI.
   - Prefer events and dirty flags over polling.
   - Never scan all surfaces, entities, players, or persistent records every tick.
   - Give unavoidable background work a deterministic item-count budget and continue it through a persistent cursor or queue on later ticks.
   - Use `on_nth_tick` for periodic work and choose intervals proportional to urgency.
   - Refresh only connected players with the relevant interface open, and only dirty components.
   - Cache stable lookups and maintain indexes from build/remove/configuration events.
   - Profile representative large saves; use profiler results for measurement, never wall-clock timing to control synchronized game-state work.
7. Compose a native layout.
   - Use standard title bars, draggable space, frame action buttons, shallow frames, tables, flows, tabbed panes, and scroll panes.
   - Give each visible region exactly one scroll owner per axis; never nest vertical scroll panes.
   - Keep list headers, summaries, filters, and pagination controls outside the scrolling row container.
   - Set scroll policy deliberately and retain the same scroll-pane element during ordinary refreshes.
   - Prefer consistent columns, compact rows, native spacing, restrained color, and tooltips over decorative artwork.
   - Use built-in styles first; add prototype styles only for repeated semantics.
   - Complete the polish pass in the same task; follow [references/polish-standard.md](references/polish-standard.md).
8. Localize every player-facing string.
   - Use LocalisedString arrays for captions and tooltips.
   - Keep keys in a mod-owned section.
   - Run `scripts/check_locale_keys.py <mod-folder> --prefix <section>` for each GUI section.
9. Verify lifecycle, usability, and load behavior.
   - Open, close, rebuild, configuration-change, multiplayer, resolution/scale change, and invalid-element paths.
   - Check tab stability, scroll stability, focus, `player.opened`, shortcut toggle state, empty states, long translations, and disabled actions.
   - Test mouse wheel, scrollbar-thumb dragging, page navigation, nested tabs, and long-list behavior independently.
   - Test with large synthetic collections and confirm work is bounded per tick.
   - Confirm queued work resumes correctly after save/load and configuration changes.
10. Run the mod's tests, Lua 5.2 parser, and Factorio-aware linter.

## Design standard

Follow the patterns distilled in [references/native-gui-patterns.md](references/native-gui-patterns.md). Read it before designing a new screen or performing a substantial GUI refactor.

Read [references/ups-and-state.md](references/ups-and-state.md) before adding polling, whole-world scans, background processing, caches, or persistent work queues. Its performance rules apply to the entire Factorio mod, not only GUI code.

Read [references/polish-standard.md](references/polish-standard.md) for every new screen, redesign, or substantial GUI change. This is the default expected finish, not an optional enhancement.

Use Factory Planner as an architectural reference for native density, component boundaries, tag-based event routing, targeted refresh triggers, modal layering, and localization discipline. Learn patterns; do not copy its implementation wholesale.

## Required closeout

- Confirm every referenced mod-owned locale key exists.
- Confirm automatic refresh does not replace the root frame.
- Confirm tab/filter/search state survives structural rebuilds.
- Confirm GUI actions update the smallest necessary subtree.
- Confirm no region has nested scroll panes on the same axis and the visible scrollbar moves with its content.
- Confirm runtime work is event-driven where possible and bounded by a deterministic per-tick budget otherwise.
- Confirm no unbounded whole-world or whole-state scan runs every tick.
- Confirm persistent queues, cursors, caches, and UI state initialize, migrate, clean up, and survive save/load.
- Report the expected worst-case work per tick and the profiling or load-test evidence used.
- Confirm native styles and LocalisedStrings are used consistently.
- Confirm the interface completed the full polish checklist rather than only becoming functional.
- Confirm all tabbed panes use a fixed `height` or `maximal_height` constraint, not `vertically_stretchable = true`, to avoid layout recursion.
- Confirm every custom GUI style has a `parent` inheriting from a Factorio base style.
- State whether validation included an actual in-game smoke test or mocks/static checks only.
