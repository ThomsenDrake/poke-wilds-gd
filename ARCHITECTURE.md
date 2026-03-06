# Architecture

This repo uses a fixed layer layout so agents can reason about structure mechanically instead of inferring it from local patterns.

## Layers

- `app`: scene entrypoints and composition only.
- `runtime`: Godot-facing orchestration, mutable session state, save/load, and smoke wiring.
- `domain`: gameplay rules and deterministic state transitions.
- `data`: source-data parsing and catalog lookup.
- `ui`: presentation controllers and UI-only scene behavior.
- `core`: small shared primitives used by multiple layers.

## Allowed Dependencies

- `app -> app, runtime, ui, core`
- `runtime -> runtime, domain, data, core`
- `ui -> ui, runtime, core`
- `domain -> domain, core`
- `data -> data, core`
- `core -> core`

Anything else is a structural violation.

## Scene Contracts

- `scenes/app/` scenes may reference `app`, `runtime`, and `ui`.
- `scenes/ui/` scenes may reference only `ui`.

## Current Subsystems

- `app_bootstrap`: top-level scene wiring and boot lifecycle.
- `session_runtime`: session state, save/load, runtime traces, music routing, and smoke scenario bootstrapping.
- `world_runtime`: overworld view, player controller, and world generation.
- `pokemon_data`: source-data parsing and species/move catalogs.
- `pokemon_progression`: Pokemon stat, move, and EXP rules.
- `battle_loop`: battle runtime, battle rules, and battle UI.
- `menu_ui`: start menu and message box presentation.

## Mechanical Invariants

- Every script and scene must belong to a registered subsystem.
- Every registered subsystem must have a spec doc, validation commands, trace coverage, and a quality-score row.
- `scripts/app/*.gd` and `scripts/ui/*.gd` must stay under 220 lines.
- Other `scripts/**/*.gd` files must stay under 320 lines.
- `*.tscn` files must stay under 250 lines.

## Trace Contract

Structured runtime traces are JSONL records with:

- `event`
- `ts_msec`
- `source`
- `payload`

See [docs/references/trace-events.md](docs/references/trace-events.md) for the required event set.
