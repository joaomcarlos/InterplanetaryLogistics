---
name: factorio-ui-mockup
description: Rebuild Factorio mod GUIs from screenshots, mockups, and sliced UI assets. Use when Codex needs to analyze a Factorio UI mockup, distinguish baked static artwork from dynamic GUI elements, create cleaned full-window or panel background PNGs, register sprites/styles, align live LuaGuiElement trees, and verify Factorio API/runtime safety for mod UI code.
---

# Factorio UI Mockup

Use this skill for Factorio mods where a UI is being reconstructed from mockups, screenshots, and `graphics/ui` assets.

## Core Workflow

1. Inspect project rules first: read `AGENTS.md`, `standard.md`, and existing GUI/style/sprite modules.
2. Inventory assets with image dimensions. Treat deleted files and stale sprite registrations as crash risks.
3. Analyze the mockup visibly before editing. List baked whole-section slices, dynamic elements, overlap problems, and sizing/position mismatches.
4. Separate layers:
   - Window/static layer: chrome, background art, borders, section frames, static header chrome.
   - Panel inner layer: empty regions where dynamic lists/settings render.
   - Repeated component layer: rows, science slots, toggles, arrows, search buttons, labels.
5. If panel-clean slices are missing, prefer a deterministic cleaned full-window background from the mockup over generative image editing.
6. Register only existing image files in `data:extend`. Never leave sprite prototypes pointing at deleted slice paths.
7. Build LuaGuiElement trees so static artwork is background/spacers and dynamic controls sit over cleared areas. Avoid drawing baked mockup sections behind live controls.
8. After edits, verify:
   - all referenced files exist;
   - modified Lua parses where local tooling allows;
   - Factorio GUI style fields and sprite paths are plausible;
   - recursive GUI helpers nil-check `player`, elements, tags, and children;
   - dynamic refresh code does not assume stale child indexes.

## Deterministic Background Cleaning

Use `scripts/clean_mockup_background.py` when a full mockup should become a reusable UI background with dynamic interiors removed.

Input rectangle JSON shape:

```json
{
  "clear": [
    {"box": [768, 63, 1056, 183], "color": [48, 48, 48, 242]}
  ],
  "restore": [
    {"box": [1378, 297, 1621, 326]}
  ],
  "lines": [
    {"from": [39, 335], "to": [554, 335], "color": [8, 9, 9, 110], "width": 1, "repeat_y": {"step": 52, "until": 831}}
  ]
}
```

Run:

```powershell
python <skill>/scripts/clean_mockup_background.py --input graphics/mockup-reference.png --output graphics/ui/window-background-clean.png --rects rects.json
```

Use rectangles that stop inside ornate borders. Restore static widgets such as search box chrome only when they should remain baked into the background.

## Factorio-Specific Guidance

- Prefer native Factorio frames for live controls, but use transparent frames/spacers over a cleaned full-window background when exact mockup chrome/art is required.
- `sprite-button.sprite`, `hovered_sprite`, and `clicked_sprite` must refer to registered sprite names, `item/...`, `technology/...`, or valid utility sprite paths.
- `graphical_set.base.filename` must point at an existing mod file; stale generated slice manifests are common crash sources.
- Do not use mockup images that already contain sample rows/icons/text as row backgrounds unless the repeated live row content has been removed from the bitmap.
- Keep repeated row widths equal to their background asset widths. Account for every child width plus margins/padding.
- Scroll panes add behavior and sometimes scrollbar space. If the mockup has a baked scrollbar, either clear it or disable custom baked scrollbar use and let Factorio draw the live one.
- For live lists, name important child flows instead of relying on `children[#children]`; later decorative sprites often break index assumptions.
- Do not assume local standalone Lua matches Factorio's Lua version. If local `luac` rejects existing Factorio-supported syntax, isolate or shim the check and explain the limitation.

## Missing Asset Response

When exact reconstruction is impossible from available assets, say so explicitly and list the missing pieces in user-facing language. Do not pretend contaminated slices can produce pixel-perfect output.

Use this wording when appropriate:

`hey mate, I really tried but for this list, you dont have any slices I can use to build them`

Then list the missing clean slices or atomic assets.

## References

Read `references/factorio-ui-checklist.md` for a compact checklist before final validation.
