# Native Factorio UI polish standard

## Contents

- Definition of done
- Information hierarchy
- Layout and rhythm
- Visual language
- Data-dense lists
- Controls and interaction states
- Tooltips and progressive disclosure
- Empty, loading, warning, and failure states
- Responsive behavior
- Localization and accessibility
- Motion and refresh stability
- Final in-game polish loop

## Definition of done

A native GUI is complete only when it is useful, stable, coherent, efficient, and visually refined in the running game. Functional controls with default spacing are not a finished design.

Complete polish in the same implementation task unless the user explicitly asks for a rough prototype.

## Information hierarchy

- Start each screen with the player's primary question and most important action.
- Put summaries and attention counts above detail lists.
- Use tabs for distinct mental models, not arbitrary code boundaries.
- Separate routine objects from objects requiring attention.
- Keep primary actions visible; move secondary explanation into tooltips.
- Use headings, subheadings, muted context, and whitespace to establish reading order.
- Avoid showing internal IDs, implementation states, or debug language unless they help the player act.

## Layout and rhythm

- Use a small spacing system consistently, such as 4 px for tight internal gaps, 8 px for related groups, and 12-16 px between sections.
- Align columns, controls, icons, and baselines across every row.
- Keep row height consistent within a list.
- Keep headers fixed outside scrolling content.
- Balance density with scanability; do not fill every pixel merely because the GUI permits it.
- Use stretchable spacers intentionally so title bars and action groups remain aligned.
- Keep widths centralized and verify their sum fits the content region at supported UI scales.
- Treat each table as a measurable width contract. Include parent padding, inter-column gaps, action-button widths, and the scrollbar allowance; verify both the header and rows use the same contract. A table that leaves a large blank tail or pushes controls past the header is unfinished.
- Compare the live screen at the target resolution with the reference after every substantial pass. Inspect edges and alignment before judging colors or typography.

## Visual language

- Prefer Factorio's native frames, shallow frames, slot buttons, utility sprites, fonts, and interaction states.
- Define custom prototype styles for repeated semantics rather than repeating runtime style mutations.
- Use one coherent treatment for headings, summaries, table headers, rows, compact buttons, warnings, and empty states.
- Use restrained color for status and attention; never rely on color alone.
- Pair state color with explicit text, icon, or tooltip.
- Use item/entity/space-location rich text or slot buttons where it improves recognition.
- Avoid decorative noise, excessive borders, arbitrary colors, and inconsistent button sizes.
- Check selected-state text against the selected button background, not only against the unselected state. Orange-on-orange and yellow-on-yellow are failures even when the accent color matches the design.
- Choose native utility sprites by meaning and silhouette. Replace ambiguous bars, flags, or generic symbols when a clearer installed sprite exists; verify the name against the current Factorio utility-sprite prototype list.

## Data-dense lists

- Decide and document the default sort based on player intent.
- Split fundamentally different populations, such as managed and unmanaged vehicles.
- Put identifying information first, current state next, destination/task after it, and actions last.
- Keep important columns visible without horizontal scrolling.
- Truncate only with a tooltip containing the complete value.
- Provide search, filtering, grouping, or pagination when realistic collections exceed comfortable scrolling.
- Bound initial construction and refresh costs for large lists.
- Keep a single scroll owner per axis and verify the scrollbar thumb follows the content.

## Controls and interaction states

- Use Factorio-native button styles and consistent sizes.
- Distinguish primary, neutral, destructive, selected, disabled, and attention actions.
- Provide hover tooltips for icon-only or ambiguous controls.
- Show current state directly in toggles and buttons.
- Disable impossible actions and explain why in the tooltip.
- Keep click targets comfortably large and avoid tightly packed accidental actions.
- Preserve tab, filter, search, focus, and scroll context after actions.

## Tooltips and progressive disclosure

- Use concise labels in the main surface and detailed explanations in tooltips.
- Tooltips should explain consequences, blockers, modifier-click behavior, full routes, and abbreviated values.
- Lead with a clear tooltip title and group supporting details on separate lines.
- Do not hide required information exclusively in tooltips.

## Empty, loading, warning, and failure states

- Give each list a purpose-specific empty message, not a generic blank area.
- Explain the next useful action when possible.
- Show unavailable, paused, stale, waiting, and failed states explicitly.
- Put actionable failures in an attention view.
- Distinguish temporary loading/waiting from errors.

## Responsive behavior

- Account for display resolution and UI scale.
- Keep the interface within the usable screen area.
- Define a compact layout or reduced optional columns for narrow displays.
- Recenter or resize on resolution and display-scale events.
- Test long translations, large numbers, long platform names, and rich-text content.
- Avoid clipped controls and hidden horizontal overflow.
- Test at least one compact and one wide resolution. Recalculate or redistribute optional-column space instead of allowing headers, rows, and controls to use different effective widths.

## Localization and accessibility

- Localize every visible string and tooltip.
- Validate literal and dynamic locale-key families.
- Do not encode meaning through color alone.
- Use readable contrast and native font sizes.
- Keep labels understandable without relying on an icon.
- Verify keyboard/Escape behavior, `player.opened`, and focus handling.

## Motion and refresh stability

- Never make rows, tabs, or scrollbars jump during routine refresh.
- Update values in place and rebuild only the smallest structurally changed container.
- Avoid flicker from destroying and recreating the root frame.
- Keep ordering stable unless the documented sort key actually changes.
- Coalesce bursts of changes before refreshing expensive components.

## Final in-game polish loop

1. Open every view in the running game.
2. Populate realistic small, large, empty, and failure scenarios.
3. Test mouse wheel, scrollbar thumb, tab switching, filters, buttons, Escape, and reopening.
4. Inspect at multiple UI scales and with long names/translations.
5. Correct alignment, clipping, inconsistent spacing, unclear labels, weak hierarchy, and noisy controls.
6. Measure refresh and idle UPS impact with representative data.
7. Repeat until no visible rough edges or interaction surprises remain.

When data-stage definitions changed, close and relaunch Factorio before this loop. Do not diagnose an unknown style or locale key from a session that was opened before the data-stage change.

If an in-game pass is unavailable, state that clearly. Static checks and mocks do not prove visual polish.
