# Agent Map

Use this file as the table of contents, not the encyclopedia.

## Read First

- Repo overview: [README.md](README.md)
- Layer rules and allowed dependencies: [ARCHITECTURE.md](ARCHITECTURE.md)
- Subsystem registry: [docs/registry/subsystems.toml](docs/registry/subsystems.toml)
- Reliability and validation: [docs/RELIABILITY.md](docs/RELIABILITY.md)
- Quality scorecard: [docs/QUALITY_SCORE.md](docs/QUALITY_SCORE.md)
- Tech debt tracker: [docs/tech-debt-tracker.md](docs/tech-debt-tracker.md)

## Where Knowledge Lives

- Design principles: `docs/design-docs/`
- Product behavior and supported gameplay slice: `docs/product-specs/`
- Godot/DAP and trace contracts: `docs/references/`
- Active and completed execution plans: `docs/exec-plans/`
- Generated maintenance output: `docs/generated/`

## Canonical Commands

```bash
python3 tools/check_repo_contracts.py
python3 tools/check_architecture.py
python3 tools/check_change_contract.py
python3 tools/check_quality_docs.py
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario boot
```

## Working Rules

- Keep new durable knowledge in `docs/`, not in ad hoc chat context.
- Register every subsystem and keep its `spec_doc`, validation commands, trace events, and quality row up to date.
- Preserve the fixed layer structure under `scripts/` and `scenes/`.
- Prefer adding or tightening mechanical checks over adding prose-only guidance.
- Keep `scripts/app/*.gd` and `scripts/ui/*.gd` under the line budget; split responsibilities early.
- Emit or update structured trace events when adding user-visible runtime behavior.
- Do not reintroduce large state buckets like the original monolithic `game_state.gd`.

## Validation Expectations

- Static checks must pass before asking for review.
- Use the DAP smoke runner for runtime validation when the Godot editor is listening on `127.0.0.1:6006`.
- Scenario coverage currently starts with `boot`, `overworld_step`, `menu_save`, and `wild_battle`.

## Common Entry Points

- App scene: `res://scenes/app/Main.tscn`
- Autoload runtime: `res://scripts/runtime/game_runtime.gd`
- Battle UI: `res://scripts/ui/battle_view.gd`
- Source data catalog: `res://scripts/data/pokemon_catalog.gd`
- Trace logger: `res://scripts/core/trace_logger.gd`
