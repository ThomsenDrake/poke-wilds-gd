Status: current
Last verified: 2026-07-20
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
Run `field_move` after touching the party screen, harvest resolution, or traversal gating. It proves a `cut`-blocked tile clears and stays walkable after a save round-trip.
Run `harvest_flow` after touching the harvest resolver, world overrides, or save schema. It proves capability refusals, cut/dig/smash yields, and override persistence.
Run `world_consistency_audit` after touching world rendering, prop scatter, traversal, or draw order. It proves tile logic/render/collision agreement plus player-vs-prop spatial, z-order, and tall-grass contracts.
Run `battle_anim` after touching the attack animation pipeline, battle turn structure, or battle audio. It plays a scripted animated move end to end and asserts the animation trace, sound, and turn resolution. Animations are frame-paced (deterministic at any refresh rate), and KO blows play before the battle closes.
Run `ui_render_audit` after touching any UI scene or the battle surface. It verifies expected strings, label overlap, and cursor pairs against the art-anchored render model, and (windowed only) runs the pixel lint; heuristic pixel findings emit `quarantine_finding` traces that report without failing until graduated.
Run `overworld_step` and `wild_battle` together after touching player animation timing, battle presentation, or scene-level UI transitions. Static checks will not catch sprite-sheet frame mapping, stage-scaling drift, stacked HUD regressions, or broken battle cursor navigation.

## Automated playtests

```bash
python3 tools/run_playtests.py                    # journey, soak, and all four audits
python3 tools/run_playtests.py --include-smoke    # everything plus smoke scenarios and visual_sweep
```

`playtest_journey` scripts a full player loop (fresh game, overworld steps, a battle played to completion, menu navigation, save round-trip). `playtest_soak` runs a seeded bot (~150 iterations of walking, battles, menu cycles, saves) asserting HP/PP/bag invariants every iteration. `nav_audit` proves traversal agreement (blocked/walkable tiles, field-move gates) and battle/menu navigation reachability with model/cursor consistency. `texture_audit` loads every battle sprite and overworld tile texture through the real pipelines (frame shape, keying). `data_audit` proves encounter-pool battle viability, instance integrity across levels, and bag/catalog resolution. `layout_audit` proves worst-case label fit and cursor alignment across battle and menu screens. Every scenario — smoke or playtest — backs up the player's save file before running and restores it afterward. The runner uses the editor DAP endpoint when available and falls back to headless Godot otherwise; it writes `.godot-smoke/playtest-report.json` and exits nonzero on any failure. Warnings are reported, not failed; exceptions and missing events fail.

Transport honesty: under `PLAYTEST_FORCE_HEADLESS=1`, windowed-only scenarios (`WINDOWED_ONLY_SCENARIOS = {visual_sweep, visual_sweep_update}`, single-sourced in `tools/godot_dap_smoketest.py`) are reported skipped-with-reason, never failed — the summary line reads e.g. `summary: 19/19 (1 skipped-headless)` and the exit code stays 0 whenever only transport skips occurred. `display_matrix` is deliberately NOT in that set: it runs under force-headless and self-skips its pixel work in-engine (`display_matrix.gd:44-47`), still emitting `display_matrix_passed` with `{skipped: headless}` — a distinct, pre-existing in-engine skip, which is why the harness skip count stays 1. (`WINDOWED_SUBPROCESS_SCENARIOS`, which does include `display_matrix`, is only the windowed-subprocess launch set used when NOT force-headless.) `godot_dap_smoketest.py` run directly shares the semantics: it prints a `SKIP:` line, writes an `ok: true` result file with `skipped_reason`, and exits 0.

Report stamps: each run writes `head_sha` (`git rev-parse HEAD`) plus `godot_version`, `window`, and `renderer` harvested from the last `snapshot_captured` trace into `.godot-smoke/playtest-report.json` — absent fields are recorded as `null`, never faked (headless-only runs have all three null, `head_sha` still present). `head_sha` is the freshness-refusal hook for `verify_all.py`. Each run also sweeps stale `.godot-smoke/result-*.json` files older than the run start so stale reds cannot contradict the report. `check_repo_contracts.py` verifies that a present report carries the `head_sha` and `godot_version` keys (nulls allowed).

## Visual verification

```bash
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario visual_sweep         # compare against baselines
python3 tools/godot_dap_smoketest.py --project /absolute/path/to/poke-wilds-godot --scene res://scenes/app/Main.tscn --scenario visual_sweep_update  # accept new baselines
```

`visual_sweep` captures a deterministic 16-shot set (fixed seed, crafted party including a strip-sprite canary species, fixed wild battle) to `.godot-smoke/shots/` at a canonical 1152x648 window size (applied and restored per run) and diffs it against `docs/generated/visual-baselines/` via `tools/visual_diff.py`; any shot drifting more than 0.5% of pixels fails the scenario. Run `visual_sweep_update` to accept intentional visual changes. Captures require a windowed run (editor DAP launch); under `PLAYTEST_FORCE_HEADLESS=1` windowed-only scenarios are reported skipped-with-reason instead of failing (see Automated playtests above). The diff tool catches pixel drift against what exists — but a human or agent should still READ new shots when states are added, since baselines only guard what already exists.

All three windowed lanes (`visual_sweep`, `ui_render_audit`'s pixel half, `display_matrix`) use the shared capture contract in `scripts/app/snapshot_capture.gd` (subsystem `vision_fidelity`; spec [product-specs/vision-fidelity.md](product-specs/vision-fidelity.md)): a `RenderingServer.frame_post_draw` readback guard added AFTER each scenario's existing settle waits, plus a validity oracle that classifies a capture as valid or as `blank`/`uniform`/`magenta`/`undersize`/`headless` with a `transport` (headless) vs `regression` (windowed) classification. The lanes consume it at different depths: only `visual_sweep` runs the full `capture()` pipeline, so only its shots emit `snapshot_captured` (with a `trace_cursor` join key into the trace log) on a valid capture; `ui_render_audit`'s pixel half runs the guard + oracle directly and emits quarantine-tier `capture_invalid` only on an invalid verdict (a valid pixel-half shot emits no per-shot trace); `display_matrix` adopts the guard alone around each per-size readback. `capture_invalid` never fails a scenario on its own — except in `visual_sweep`, where an invalid windowed capture still fails red, now with a trace explaining why. A magenta battle SubViewport readback (Godot 4.6 regression #115402, fixed only in 4.7) engages a traced root-viewport-crop fallback in `ui_render_audit`; a magenta `capture_invalid` on the pinned 4.6.1 binary is the guard working, not a sweep defect. Run `visual_sweep` after touching capture/readback paths, window sizing, battle-surface art, or renderer settings; run `ui_render_audit` after touching any UI scene or the battle surface. A duplicate-capture hook (env `PLAYTEST_CAPTURE_DUPCHECK=1` or a scenario option; default off) re-captures each shot and traces any nonzero pair delta as `nondeterministic_pair` with the diff count and first byte offset.

`display_matrix` resizes the window across six sizes (including odd, fractional-inducing ones) and verifies the battle surface renders without scale degradation at each: a block-uniformity check (integer scales produce byte-identical pixel blocks; fractional scales break block periodicity) plus a round-trip content consistency diff. Run it after touching display/layout scaling in any UI.

## Agent vision review

After any sweep whose shots change, a vision-capable reviewer reads every shot against `docs/references/vision-review-rubric.md` and writes `.godot-smoke/vision-review.json` (per shot: defect class, region, severity, confidence). Findings are quarantine-tier — reported, never red — unless a coded oracle independently confirms the same defect.

## Current risks

- Smoke scenarios depend on a locally running Godot editor exposing DAP on `127.0.0.1:6006`.
- An empty species catalog now skips encounters with a `warning` trace instead of fabricating a synthetic mon; watch for that warning after touching `scripts/data/`.
- Battle mechanics follow the mainline formulas (type chart, stat stages, status, capture, growth curves); unsupported move effects degrade to plain hits and surface a `warning` trace with the effect id.
- Save schema v2 migrates v1 payloads on load; the migration is covered by the `menu_save` and `field_move` scenarios but not by a dedicated fixture test.
