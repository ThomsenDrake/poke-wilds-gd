# PokeWilds Godot

This repository is a Godot reimplementation scaffold for a playable slice of PokeWilds, optimized for agent legibility and repeatable validation. The goal is not to turn the project into a standalone harness. The goal is to make the project easier for agents to inspect, modify, validate, and keep coherent as the codebase grows.

## Current slice

- Boot into an overworld scene backed by seeded procedural terrain.
- Move on a tile grid, trigger wild encounters in grass, and save player position.
- Start a wild battle, use moves, throw Poke Balls, use Potions, gain EXP, and level up.
- Open the start menu to inspect the party, swap the lead slot, save, or start a new run.
- Load source data from the checked-in `pokewilds/` asset and data subtree.

## Start Here

- Repo map: [AGENTS.md](AGENTS.md)
- Layer rules: [ARCHITECTURE.md](ARCHITECTURE.md)
- Design index: [docs/design-docs/index.md](docs/design-docs/index.md)
- Product specs: [docs/product-specs/index.md](docs/product-specs/index.md)
- Reliability commands: [docs/RELIABILITY.md](docs/RELIABILITY.md)
- Quality scorecard: [docs/QUALITY_SCORE.md](docs/QUALITY_SCORE.md)
- Active execution plan: [docs/exec-plans/active/harness-engineering-reorientation.md](docs/exec-plans/active/harness-engineering-reorientation.md)

## Canonical Commands

```bash
python3 tools/check_repo_contracts.py
python3 tools/check_architecture.py
python3 tools/check_change_contract.py
python3 tools/check_quality_docs.py
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario boot
```

## Layout

- `scripts/app/`: top-level scene wiring.
- `scripts/runtime/`: Godot-facing orchestration and mutable runtime services.
- `scripts/domain/`: gameplay rules and pure state transitions.
- `scripts/data/`: parsers and data catalogs for the source asset tree.
- `scripts/ui/`: presentation controllers and UI scenes.
- `scripts/core/`: small shared primitives.
- `docs/`: system of record for design, specs, reliability, quality, and execution history.

## Source Assets

The checked-in `pokewilds/` subtree is treated as external source data and art content for the port. See [docs/references/source-assets.md](docs/references/source-assets.md) for the files the runtime parses directly.
