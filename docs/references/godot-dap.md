Status: current
Last verified: 2026-03-06
Review cadence days: 30
Source paths: tools/godot_dap_smoketest.py, scenes/app/Main.tscn, scripts/runtime/smoke_scenario_runner.gd

# Godot DAP Reference

## Endpoint

- `127.0.0.1:6006` is the Godot Debug Adapter Protocol endpoint used by the local smoke runner.

## Launch contract

The smoke runner launches with:

```json
{
  "command": "launch",
  "arguments": {
    "project": "/absolute/path/to/project",
    "scene": "res://scenes/app/Main.tscn"
  }
}
```

After launch, the runner sends `configurationDone`.

## Scenario mechanism

`tools/godot_dap_smoketest.py` writes `.godot-smoke/scenario.json` into the repo root before launch. `scripts/runtime/smoke_scenario_runner.gd` consumes that file on boot and the app executes one of these scenarios:

- `boot`
- `overworld_step`
- `menu_save`
- `wild_battle`

When the imported species catalog is empty, the battle scenario uses a synthetic fallback mon so the smoke path still exercises battle start, action handling, trace emission, and teardown.

## Canonical command

```bash
python3 tools/godot_dap_smoketest.py \
  --project /absolute/path/to/poke-wilds-godot \
  --scene res://scenes/app/Main.tscn \
  --scenario boot
```
