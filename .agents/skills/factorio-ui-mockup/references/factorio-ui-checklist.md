# Factorio UI Mockup Checklist

## Asset Audit

- List `graphics/ui` and `graphics/ui/slices` separately.
- Record PNG dimensions before trusting style widths.
- Search for stale references to deleted files, especially generated slice manifests.
- Register only existing files in `data:extend`.

## Mockup Analysis

- Identify which bitmap areas are static art.
- Identify dynamic areas: rows, item slots, search fields, buttons, toggles, checkboxes, radio buttons, timers, scrollbars.
- Flag contaminated slices: any image that contains sample text, sample items, sample rows, or whole UI sections.
- Compare actual slice dimensions with style widths and live child widths.

## Layering Rules

- Use one static background layer for chrome/art.
- Use transparent or native frames for panel overlays.
- Use dynamic LuaGuiElements for stateful controls and lists.
- Avoid stacking live labels/icons over baked labels/icons.
- Keep search box/button chrome static only if the live textfield/button is hidden or aligned over it intentionally.

## LuaGuiElement Safety

- Check `game.get_player(...)` before using `player.force`.
- Check `gutil.get_child(...)` results before setting style/properties.
- Check `elm.tags` before reading tag keys.
- Name important dynamic child flows if later code refreshes them.
- Avoid relying on `pairs` order for visual ordering when the order matters; use ordered arrays.

## Verification

- Run file-existence checks for every registered PNG.
- Run local syntax checks where possible; explain Factorio Lua version mismatches.
- Search for deleted path strings after edits.
- Inspect generated PNG output visually before wiring it into code.
- Re-read changed styles against Factorio GUI style names and properties.
