# PokeWilds Godot

This repository is a Godot reimplementation scaffold for a playable slice of PokeWilds, optimized for agent legibility and repeatable validation. The goal is not to turn the project into a standalone harness. The goal is to make the project easier for agents to inspect, modify, validate, and keep coherent as the codebase grows.

## Current slice

- Boot into an overworld scene backed by seeded procedural terrain with progressive biomes (rarer biomes farther from a navigable, reachability-proven spawn).
- Move on a tile grid, trigger wild encounters in grass, and harvest trees, cacti, swamp trees, snow trees, and rock cliffs with party-capable field moves — cleared tiles mutate the world permanently (save schema v3 world overrides).
- Start a wild battle, use moves (per-move source animation sets where they exist, a synthesized lunge/flash fallback otherwise), throw Poke Balls, use Potions, gain EXP, level up, and evolve. A full-party capture is non-losing: the overflow Pokemon is held at your campsite and retrieved from the party screen.
- Open the start menu to inspect the party (swap lead, summary, field moves, campsite retrieve) and the bag (use items), save (atomic temp+rename writes), or start a new run (confirm-gated through a message box).
- Validate the whole slice with one command: `python3 tools/verify_all.py` — the local gate that orchestrates the static checks, determinism pins, the transport-honest headless playtest/smoke suite, the windowed pixel lanes (`ui_render_audit` + `visual_sweep`), and the legibility report.
- Load source data from the checked-in `pokewilds/` asset and data subtree.

## Start Here

- Repo map: [AGENTS.md](AGENTS.md)
- Layer rules: [ARCHITECTURE.md](ARCHITECTURE.md)
- Design index: [docs/design-docs/index.md](docs/design-docs/index.md)
- Product specs: [docs/product-specs/index.md](docs/product-specs/index.md)
- Reliability commands: [docs/RELIABILITY.md](docs/RELIABILITY.md)
- Quality scorecard: [docs/QUALITY_SCORE.md](docs/QUALITY_SCORE.md)
- Active execution plans: [docs/exec-plans/active/harness-engineering-reorientation.md](docs/exec-plans/active/harness-engineering-reorientation.md) and [docs/exec-plans/active/pokewilds-feature-completion.md](docs/exec-plans/active/pokewilds-feature-completion.md)

## Canonical Commands

```bash
python3 tools/verify_all.py            # the one-command local gate (static gates + determinism + headless suite + windowed lanes + legibility)
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
