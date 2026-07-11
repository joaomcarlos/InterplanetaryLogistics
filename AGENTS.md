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

- The Fleet Monitor is the first dashboard view.
- Automatic and manual dashboard refreshes must not reset dashboard navigation, request selection, scroll position, or replace the open frame.
- Native list views use one scrollbar per axis; Delivery Fleet is separate from Other Platforms and both are sorted by ship name.
- Native Factorio GUI work is expected to be production-ready and highly polished by default; visual hierarchy, spacing, native styles, interaction states, responsive sizing, tooltips, empty states, and in-game QA are part of completion.
- Dashboard controls that are visually square use square native utility-sprite buttons with localized tooltips; do not introduce a custom sprite-based design system.

## Project Overview

Factorio 2.0 Space Age mod that routes requester-chest and construction-alert shortages through enrolled space platforms. Written in Lua 5.2 targeting the Factorio mod runtime.

- Entry points: `data.lua` (data stage), `control.lua` (runtime), `settings.lua` (mod settings)
- Runtime modules live in `scripts/`
- Tests live in `tests/` and run under plain Lua 5.1+ with manual Factorio API mocks
- Locale strings live in `locale/en/`
- Lua language server config: `.luarc.json`

## Repo-Wide Rules

- Target Lua 5.2 syntax and Factorio 2.0 API
- All runtime state, reservations, route preferences, platform options, and fleet snapshots persist through `storage.interplanetary_logistics` via `scripts/state.lua`
- Never mutate a platform's permanent schedule records; only append/remove temporary records
- Deterministic iteration: sort before iterating when order affects game state (desync safety)
- Guard all `game.get_player()` calls against nil returns
- Tests must pass under `lua tests/runtime_spec.lua`, `lua tests/data_stage_spec.lua`, and `python tests/locale_spec.py`

## Child DOX Index

- `scripts/AGENTS.md` — Runtime module contracts (constants, state, util, demands, router, platforms, gui)
- `tests/AGENTS.md` — Test specs, mock patterns, and verification commands
