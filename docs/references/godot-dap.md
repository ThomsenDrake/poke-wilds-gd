Status: current
Last verified: 2026-08-10
Review cadence days: 30
Source paths: tools/godot_dap_smoketest.py, tools/run_playtests.py, scenes/app/Main.tscn, scripts/runtime/smoke_scenario_runner.gd

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

## Transport authority

The DAP transport is **launch/trace-only**: it launches the scene, drives the scenario through the `.godot-smoke/scenario.json` file-in seam, collects debugger exceptions, and asserts the required trace events. It carries no pixel/VLM authority.

The **windowed-subprocess transport** (`tools/run_playtests.py` launching the Godot binary directly — no editor) is the SOLE pixel/VLM authority. The capture post-steps are runner-side steps of that transport: the canonical region gate (`apply_region_gate`), the WCAG contrast/CVD evidence (`apply_contrast_cvd`), and the Lane-4 vision review (`apply_vision_review`, which writes `.godot-smoke/vision-review.json`). The quarantine-tier post-steps (contrast/CVD, vision review) intentionally do NOT run on the DAP transport: they are report-tier evidence that never flips `ok`, so their absence cannot hide a failure (the standing "transport divergence" note in `tools/godot_dap_smoketest.py`). The one exception is red-tier: `apply_region_step` mirrors the region gate onto DAP results because region failures flip `ok` — a revived DAP path must not pass `visual_sweep` event-only.

Extending DAP with the full post-step set was considered and rejected: it would duplicate gate logic against the repo's single-source rule. An agent that needs pixel truth runs the windowed transport; DAP answers "did it boot and behave", never "did it look right".

## Canonical command

```bash
python3 tools/godot_dap_smoketest.py \
  --project /absolute/path/to/poke-wilds-godot \
  --scene res://scenes/app/Main.tscn \
  --scenario boot
```
