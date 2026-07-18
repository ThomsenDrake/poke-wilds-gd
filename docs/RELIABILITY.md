Status: current
Last verified: 2026-07-17
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
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario biome_probe
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario biome_traverse
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario field_move
```

Run `biome_probe` after touching world generation, biome definitions, or the spawn/reachability logic. It asserts determinism, ring progression, navigable spawn, and reachability invariants in a single trace.
Run `biome_traverse` after touching traversal gating, biome encounter filtering, or the player avatar blocked path. It exercises biome crossing, traversal-gate blocking, and a biome-aware wild battle.
Run `field_move` after touching the party screen, field-move unlock flow, or traversal gating. It proves a `cut`-gated tile becomes walkable after the party-screen field move fires.
Run `world_consistency_audit` after touching world rendering, prop scatter, traversal, or draw order. It proves tile logic/render/collision agreement plus player-vs-prop spatial, z-order, and tall-grass contracts.
Run `battle_anim` after touching the attack animation pipeline, battle turn structure, or battle audio. It plays a scripted animated move end to end and asserts the animation trace, sound, and turn resolution.
Run `ui_render_audit` after touching any UI scene or the battle surface. It verifies expected strings, label overlap, and cursor pairs against the art-anchored render model, and (windowed only) runs the pixel lint; heuristic pixel findings emit `quarantine_finding` traces that report without failing until graduated.
Run `overworld_step` and `wild_battle` together after touching player animation timing, battle presentation, or scene-level UI transitions. Static checks will not catch sprite-sheet frame mapping, stage-scaling drift, stacked HUD regressions, or broken battle cursor navigation.

## Automated playtests

```bash
python3 tools/run_playtests.py                    # journey, soak, and all four audits
python3 tools/run_playtests.py --include-smoke    # everything plus smoke scenarios and visual_sweep
```

`playtest_journey` scripts a full player loop (fresh game, overworld steps, a battle played to completion, menu navigation, save round-trip). `playtest_soak` runs a seeded bot (~150 iterations of walking, battles, menu cycles, saves) asserting HP/PP/bag invariants every iteration. `nav_audit` proves traversal agreement (blocked/walkable tiles, field-move gates) and battle/menu navigation reachability with model/cursor consistency. `texture_audit` loads every battle sprite and overworld tile texture through the real pipelines (frame shape, keying). `data_audit` proves encounter-pool battle viability, instance integrity across levels, and bag/catalog resolution. `layout_audit` proves worst-case label fit and cursor alignment across battle and menu screens. Every scenario — smoke or playtest — backs up the player's save file before running and restores it afterward. The runner uses the editor DAP endpoint when available and falls back to headless Godot otherwise; it writes `.godot-smoke/playtest-report.json` and exits nonzero on any failure. Warnings are reported, not failed; exceptions and missing events fail.

## Visual verification

```bash
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario visual_sweep         # compare against baselines
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario visual_sweep_update  # accept new baselines
```

`visual_sweep` captures a deterministic 16-shot set (fixed seed, crafted party including a strip-sprite canary species, fixed wild battle) to `.godot-smoke/shots/` and diffs it against `docs/generated/visual-baselines/` via `tools/visual_diff.py`; any shot drifting more than 0.5% of pixels fails the scenario. Run `visual_sweep_update` to accept intentional visual changes. Captures require a windowed run (editor DAP launch); headless captures are blank, and baselines are stable per-machine (resolution-dependent). The diff tool catches pixel drift against what exists — but a human or agent should still READ new shots when states are added, since baselines only guard what already exists.

## Agent vision review

After any sweep whose shots change, a vision-capable reviewer reads every shot against `docs/references/vision-review-rubric.md` and writes `.godot-smoke/vision-review.json` (per shot: defect class, region, severity, confidence). Findings are quarantine-tier — reported, never red — unless a coded oracle independently confirms the same defect.

## Current risks

- Smoke scenarios depend on a locally running Godot editor exposing DAP on `127.0.0.1:6006`.
- An empty species catalog now skips encounters with a `warning` trace instead of fabricating a synthetic mon; watch for that warning after touching `scripts/data/`.
- Battle mechanics follow the mainline formulas (type chart, stat stages, status, capture, growth curves); unsupported move effects degrade to plain hits and surface a `warning` trace with the effect id.
- Save schema v2 migrates v1 payloads on load; the migration is covered by the `menu_save` and `field_move` scenarios but not by a dedicated fixture test.
