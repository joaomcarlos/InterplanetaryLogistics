# Native Factorio GUI patterns

## Contents

- Architecture
- Build versus refresh
- Scroll panes and long lists
- State management
- UPS and refresh performance
- Event routing
- Layout and styling
- Localization
- Accessibility and resilience
- Factory Planner study notes
- Review checklist

## Architecture

Separate responsibilities:

- GUI builders create stable element trees.
- Refreshers update an existing component or subtree.
- Event routing resolves actions from element tags and delegates behavior.
- Persistent per-player state owns selections and preferences, not LuaGuiElement references.
- Runtime LuaGuiElement references may be cached only as ephemeral convenience and must be validated before use.

Split large interfaces by screen or component. Give each component a build entrypoint, refresh entrypoint, and event definitions. Centralize event registration to avoid duplicate `script.on_event` handlers.

## Build versus refresh

Treat rebuilding as a structural operation:

- Rebuild when rows are added/removed, columns change, or screen mode changes.
- Refresh in place when text, number, sprite, color, visibility, enabled state, tooltip, or selection changes.
- Prefer refreshing one component over the entire dialog.
- Never rebuild the root frame on a timer.
- Avoid clearing a scroll pane while the player is reading it unless its contents structurally changed.

Factorio exposes read/write `selected_tab_index`, so capture and restore it around unavoidable rebuilds. It offers methods to move scroll position but no readable scroll offset; preserving scroll therefore means retaining the scroll-pane element.

## Scroll panes and long lists

- Assign one scroll pane as the sole vertical scroll owner for each visible list region.
- Never place a vertical scroll pane inside another vertical scroll pane. For nested tabs, make the outer tab content a plain flow and put one scroll pane inside each leaf view.
- Keep the title, summary, filters, column header, footer, and pagination outside the scrolling row container.
- Use `vertical_scroll_policy = "auto"` for long lists and `horizontal_scroll_policy = "never"` when columns are designed to fit.
- Give the scroll pane a bounded height or stretch contract; do not give its row container a competing fixed content height.
- Retain the scroll-pane element during value refreshes. Update row children in place.
- Rebuild only the row container when membership/order changes, and prefer pagination for large collections so rebuild cost and scroll disruption stay bounded.
- Avoid controls inside rows that capture wheel behavior unexpectedly.
- Test mouse wheel scrolling, thumb dragging, track clicking, tab switching, page switching, and resolution/UI-scale changes.
- If content moves but the thumb does not, inspect for nested scroll panes, replacement of the active scroll element, or scrolling a different pane than the visible bar belongs to.

## State management

Store durable UI state by player index:

```lua
state.gui[player_index] = {
  main_tab = 1,
  sub_tab = 1,
  filter = "all",
  sort = "name",
  search = ""
}
```

Do not store LuaGuiElement objects in persistent state. Before a rebuild, read the live selected tab and editable values. Use a transient `rebuilding` guard so programmatic selection changes cannot overwrite the intended state.

React to display resolution and display scale changes when window sizing depends on them.

Keep domain state separate from presentation state. Initialize all persistent fields centrally, migrate old schemas explicitly, and clean up per-player state when players are removed. Store stable IDs rather than runtime objects.

## UPS and refresh performance

- Refresh only interfaces that are open, and only components whose inputs changed.
- Maintain dirty sets keyed by player, component, or domain object instead of rebuilding every open GUI.
- Coalesce repeated changes so one component refresh occurs after a burst of events.
- Avoid constructing large LocalisedStrings, tooltips, sorted lists, or row trees every tick.
- Cache stable sorted/indexed views and invalidate them when source data changes.
- Spread structural creation of very large lists over deterministic batches when practical, or paginate/filter the view.
- Keep hover and text-change handlers lightweight; debounce or rate-limit expensive downstream work.

See [ups-and-state.md](ups-and-state.md) for whole-mod runtime rules.

## Event routing

Prefer tags over parsing names for domain actions:

```lua
button.tags = {
  mod = "my-mod",
  action = "toggle-platform",
  platform_index = platform.index
}
```

Use one handler per Factorio GUI event type, reject elements not owned by the mod, validate player/element state, and dispatch to action functions. Use names for unique lookup targets such as the root frame or main tabbed pane.

Rate-limit expensive clicks or text refreshes when appropriate. Keep hover-only work lightweight.

## Layout and styling

- Use a screen frame with a standard title bar, draggable spacer, and `frame_action_button` controls.
- Group content with native frames, shallow frames, tables, flows, tabs, and scroll panes.
- Prefer tables for aligned data. Keep explicit widths centralized and ensure totals fit the content area.
- Use compact row heights and consistent spacing for dense management screens.
- Use built-in utility sprites and prototype rich-text tags for game concepts.
- Use color to communicate state, not decoration; pair color with text or icon meaning.
- Put secondary explanations and modifier-click behavior in tooltips.
- Create custom prototype styles only when a repeated semantic cannot be expressed cleanly with built-in styles plus small style adjustments.
- Every custom GUI style must specify a `parent` to inherit proper default sizing from Factorio's base styles. Styles without a parent can default to zero size and contribute to layout failures.
- All tabbed panes must use a fixed `height` or `maximal_height` constraint, not `vertically_stretchable = true`. `vertically_stretchable` is a valid `StretchRule` on `TabbedPaneStyleSpecification` (default `"auto"`), but setting it to `"on"` when tab content is also `vertically_stretchable` creates a circular layout dependency (tabbed-pane asks content for preferred height, content defers back) causing infinite recursion in Factorio's C++ `TabbedPane::setSize` and a stack overflow crash. The base game uses `maximal_height` on tabbed panes instead.

## Localization

Every player-facing caption, tooltip, empty state, warning, column heading, setting name, and setting description must be localized.

- Use `{"section.key", parameter}` or composite `{"", ...}` LocalisedStrings.
- Keep a consistent mod-owned namespace such as `[my-mod-gui]`.
- Avoid dynamically constructed keys unless every possible key is declared and tested.
- Validate English as the canonical complete locale before relying on fallback behavior.
- Restart/reload Factorio after changing locale files; a running session may continue showing `Unknown key` from the previously loaded mod copy.

Run:

```text
python scripts/check_locale_keys.py <mod-folder> --prefix my-mod-gui
```

## Accessibility and resilience

- Provide tooltips for icon-only controls.
- Do not rely on color alone.
- Allow long translations to expand or wrap without overlapping controls.
- Keep destructive actions visually distinct and confirm high-impact operations.
- Guard missing players, invalid elements, deleted entities, and stale domain IDs.
- Set and clear `player.opened` deliberately so Escape behavior is predictable.
- Preserve shortcut toggled state when opening and closing.
- Include clear empty, loading, unavailable, and error states.

## Factory Planner study notes

Factory Planner's public implementation demonstrates several useful native-GUI patterns:

- A central event router collects component-owned actions and dispatches through element tags.
- GUI code is split into base dialogs, reusable components, main-screen components, and modal dialogs.
- Build and refresh are distinct operations with named refresh triggers, allowing targeted updates.
- Per-player UI state and context are separate from the GUI tree.
- Modal layers, context menus, search fields, title bars, and close behavior follow Factorio conventions.
- Styles are defined centrally for repeated visual semantics.
- Dense information uses native tables, slot buttons, rich-text prototype references, and detailed tooltips.
- Player resolution and display-scale changes are handled explicitly.

Sources:

- https://mods.factorio.com/mod/factoryplanner
- https://github.com/ClaudeMetz/FactoryPlanner
- https://lua-api.factorio.com/latest/classes/LuaGuiElement.html

## Review checklist

- Root frame is stable during periodic refresh.
- Structural and value-only updates are separated.
- Tabs, filters, search, and dialog state are per player.
- Scroll panes survive ordinary refreshes.
- Each list has exactly one vertical scroll owner; its visible scrollbar tracks wheel and thumb movement.
- Events use stable ownership tags and centralized registration.
- Every action validates element, player, and referenced object.
- Native styles and utility sprites are preferred.
- All visible strings resolve through locale.
- Empty and error states are present.
- Long translations and display scaling are considered.
- Open-GUI refresh cost is proportional to dirty visible content, not total world size.
- Background work has a deterministic per-tick budget and resumes safely.
- All tabbed panes use fixed `height` or `maximal_height`, not `vertically_stretchable = true`.
- Every custom GUI style has a `parent` inheriting from a Factorio base style.
