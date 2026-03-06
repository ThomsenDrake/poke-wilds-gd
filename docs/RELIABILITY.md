Status: current
Last verified: 2026-03-06
Review cadence days: 14
Source paths: tools/check_repo_contracts.py, tools/check_architecture.py, tools/check_quality_docs.py, tools/godot_dap_smoketest.py

# Reliability

## Static checks

```bash
python3 tools/check_repo_contracts.py
python3 tools/check_architecture.py
python3 tools/check_quality_docs.py
python3 tools/check_change_contract.py
```

## Runtime smoke checks

```bash
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario boot
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario overworld_step
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario menu_save
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario wild_battle
```

## Current risks

- Smoke scenarios depend on a locally running Godot editor exposing DAP on `127.0.0.1:6006`.
- If the imported species catalog is empty, battle smoke falls back to a synthetic `SMOKE_MON` so the runtime path remains testable. Treat that as a validation escape hatch, not as a product-complete data path.
- Battle behavior is intentionally simplified and should not be treated as feature parity with upstream PokeWilds.
- Save migration is still best-effort because the project only maintains one current JSON save format.
