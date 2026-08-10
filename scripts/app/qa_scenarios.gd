extends RefCounted

# Dispatch table for self-contained audit/QA scenarios: each entry maps the
# scenario name to a script and the method that drives it (plus extra args
# appended after ctx). Keeps smoke_scenarios.gd under its line budget.

const SCENARIOS := {
	"nav_audit": [preload("res://scripts/app/nav_audit.gd"), "run", []],
	"texture_audit": [preload("res://scripts/app/qa_audits.gd"), "run_texture", []],
	"data_audit": [preload("res://scripts/app/qa_audits.gd"), "run_data", []],
	"layout_audit": [preload("res://scripts/app/layout_audit.gd"), "run", []],
	"world_consistency_audit": [preload("res://scripts/app/world_consistency_audit.gd"), "run", []],
	"ui_render_audit": [preload("res://scripts/app/ui_render_audit.gd"), "run", []],
	# Agent legibility (agent-neutral integration Phase 2): the accessibility-snapshot
	# analog — per-screen visible-Control-tree JSON dumps to .godot-smoke/ui_tree/
	# (title/menu/party/bag/battle) + the ui_tree_dump_passed/failed pair. Self-pinned.
	"ui_tree_dump": [preload("res://scripts/app/ui_tree_dump_scenario.gd"), "run", []],
	# The Phase-2 agreement gate (agent-surface completion sprint, Workstream F):
	# drives the SAME five screens through the SAME seams and asserts the ui_tree
	# dumps, the game/* Performance monitors, and the trace lifecycle AGREE —
	# closing the "MANUALLY kept in sync" gap on performance_monitors.gd. Checks
	# split into legibility_soak_checks.gd for the app budget. Self-pinned.
	"legibility_soak": [preload("res://scripts/app/legibility_soak_scenario.gd"), "run", []],
	"battle_anim": [preload("res://scripts/app/battle_anim_scenario.gd"), "run", []],
	"display_matrix": [preload("res://scripts/app/display_matrix.gd"), "run", []],
	"harvest_flow": [preload("res://scripts/app/harvest_flow_scenario.gd"), "run", []],
	"placement_flow": [preload("res://scripts/app/placement_flow_scenario.gd"), "run", []],
	# Same-press input double-fire regression (exec plan Part A5): real input-phase
	# injection proves the camp-menu closed latch swallows the toggle + context polls.
	"input_gate": [preload("res://scripts/app/input_gate_scenario.gd"), "run", []],
	# Battle-END same-press leak: a press that ends a battle (RUN / capture) must not
	# re-fire the overworld context action the same frame (the latch's battle arm).
	"battle_end_input": [preload("res://scripts/app/battle_end_input_scenario.gd"), "run", []],
	# QoL: Z on diggable ground with no Dig-capable mon stays silent (the refusal
	# toast fired on every exploratory Z); cut + capable-dig presses still speak.
	"dig_silence": [preload("res://scripts/app/dig_silence_scenario.gd"), "run", []],
	# Phase 2 camping / crafting / night-survival proofs (camping-crafting-survival.md);
	# like every non-playtest entry, they run inside smoke_scenarios' save guard.
	"camp_survival": [preload("res://scripts/app/camp_survival_scenario.gd"), "run", []],
	"craft_flow": [preload("res://scripts/app/craft_flow_scenario.gd"), "run", []],
	"night_cycle": [preload("res://scripts/app/night_cycle_scenario.gd"), "run", []],
	"time_evolution": [preload("res://scripts/app/time_evolution_scenario.gd"), "run", []],
	# Phase 3 storage box + party-management proof (storage-and-party.md).
	"storage_flow": [preload("res://scripts/app/storage_flow_scenario.gd"), "run", []],
	# Phase 4 field-move completion proof (field-moves.md): the eight zero-caller moves
	# driven by the all-field-moves party; group A + B checks split for the app budget.
	"field_moves_flow": [preload("res://scripts/app/field_moves_flow_scenario.gd"), "run", []],
	# Building playtest (field-moves.md addition B): harvest -> house with a door -> refund.
	"build_house_flow": [preload("res://scripts/app/build_house_flow_scenario.gd"), "run", []],
	# Phase 5 breeding / shinies / habitat drops / fishing proofs
	# (breeding-shinies-drops-fishing.md); dispatcher save-guarded like every
	# non-playtest entry.
	"breed_flow": [preload("res://scripts/app/breed_flow_scenario.gd"), "run", []],
	"shiny_odds": [preload("res://scripts/app/shiny_odds_scenario.gd"), "run", []],
	"habitat_drops": [preload("res://scripts/app/habitat_drops_scenario.gd"), "run", []],
	"fishing_flow": [preload("res://scripts/app/fishing_flow_scenario.gd"), "run", []],
	# Phase 6 overworld mons (overworld-pokemon.md): the gate scenario + the deterministic
	# 22/23 sweep (shared baseline dir; update never prunes foreign shots).
	"overworld_mons": [preload("res://scripts/app/overworld_mons_scenario.gd"), "run", []],
	# Configurable encounters (overworld-pokemon.md § Configurable encounters): the
	# collision-only default + the opt-in modes + the additive save round-trip. Joins the
	# double-run lane (overworld-active: contact needs live entities).
	"encounter_config": [preload("res://scripts/app/encounter_config_scenario.gd"), "run", []],
	# Comprehensive world-gen audit (bootstrap-and-overworld.md): cohesion/blending + spawn↔
	# stats + dungeon-site availability across a fixed seed list; enforcing tier gates, the
	# future-fix gaps ride the warning-tier world_gen_audit_advisory event (never gates).
	"world_gen_audit": [preload("res://scripts/app/world_gen_audit_scenario.gd"), "run", []],
	"visual_sweep_overworld": [preload("res://scripts/app/visual_sweep_overworld.gd"), "run_sweep", []],
	"visual_sweep_overworld_update": [preload("res://scripts/app/visual_sweep_overworld.gd"), "run_sweep", [{"mode": "update"}]],
	# Pokemon-state shots 20-21 (shared baseline dir; update never prunes foreign shots).
	"visual_sweep_pokemon": [preload("res://scripts/app/visual_sweep_pokemon.gd"), "run_sweep", []],
	"visual_sweep_pokemon_update": [preload("res://scripts/app/visual_sweep_pokemon.gd"), "run_sweep", [{"mode": "update"}]],
	# Fishing-state shots 26-27 (seed 2026072804; shared baseline dir; windowed-only).
	"visual_sweep_fishing": [preload("res://scripts/app/visual_sweep_fishing.gd"), "run_sweep", []],
	"visual_sweep_fishing_update": [preload("res://scripts/app/visual_sweep_fishing.gd"), "run_sweep", [{"mode": "update"}]],
	# Breeding/drops/fishing soak (self-guarded like journey/soak; the playtest_
	# prefix makes the dispatcher skip its save guard).
	"playtest_breed_soak": [preload("res://scripts/app/playtest_breed_soak_scenario.gd"), "run", []],
	"visual_sweep": [preload("res://scripts/app/visual_sweep.gd"), "run_sweep", []],
	"visual_sweep_update": [preload("res://scripts/app/visual_sweep.gd"), "run_sweep", [{"mode": "update"}]],
	"visual_sweep_camping": [preload("res://scripts/app/visual_sweep_camping.gd"), "run_sweep", []],
	"visual_sweep_camping_update": [preload("res://scripts/app/visual_sweep_camping.gd"), "run_sweep", [{"mode": "update"}]],
	# Storage-state shots 18-19 (shared baseline dir; update never prunes foreign shots).
	"visual_sweep_storage": [preload("res://scripts/app/visual_sweep_storage.gd"), "run_sweep", []],
	"visual_sweep_storage_update": [preload("res://scripts/app/visual_sweep_storage.gd"), "run_sweep", [{"mode": "update"}]],
	# Pre-Phase-7 suite expansion: the joint rng pin, v4 save stability (golden fixture
	# at docs/generated/golden-saves/v4_golden.json; update rewrites it), and the
	# Phase-6 entity soak (self-guarded: the playtest_ prefix skips the save guard).
	"rng_joint_pin": [preload("res://scripts/app/rng_joint_pin_scenario.gd"), "run", []],
	"save_stability": [preload("res://scripts/app/save_stability_scenario.gd"), "run", []],
	"save_stability_update": [preload("res://scripts/app/save_stability_scenario.gd"), "run", [{"mode": "update"}]],
	"playtest_entity_soak": [preload("res://scripts/app/playtest_entity_soak_scenario.gd"), "run", []],
	# Phase 7 Build 1 landmarks (world-depth.md): the Mansion puzzle solved on fixed
	# seed 2026072907 + footprint-local encounter scope (checks split into
	# world_depth_checks.gd for the app budget; joins the double-run lane). The
	# world-depth sweep (shots 31-32) is windowed-only like the other satellites.
	"landmark_flow": [preload("res://scripts/app/landmark_flow_scenario.gd"), "run", []],
	# Phase 7 Build 2 legendaries (world-depth.md § Legendaries): the climate-anchored
	# spawn proof — ALL SEVEN anchored (slice 2: LAVA generates; the synthetic reach-1
	# NO_ANCHOR witness), the legendary_encounter{battle_kind:"legendary"} battle-start
	# trace, the never-encounter exclusion, the white-out re-battleable + KO gone-for-good
	# (per-instance, slice 3) rematch rules. Joins the double-run lane.
	"legendary_spawn": [preload("res://scripts/app/legendary_spawn_scenario.gd"), "run", []],
	# (world_chain + beacon_selector scenarios RETIRED with world chaining — infinite-world
	# slice: the seamless plane has no edge to cross and no edge beacons. Way-stone teleport
	# stays, via the renamed WayStoneSelector — its multi-stone CHOICE + avatar-input
	# ownership witness is:)
	"waystone_selector": [preload("res://scripts/app/waystone_selector_scenario.gd"), "run", []],
	# Infinite-world slice 3: the chunk-hash scattering witness — origin-core preservation,
	# scattered-instance discovery + per-instance puzzle state, repeating-lair lifecycle.
	"content_scatter": [preload("res://scripts/app/content_scatter_scenario.gd"), "run", []],
	# Infinite-world slice 4: creation-time seed choice — custom-seed determinism (two
	# re-pinned runs byte-identical), the beach-preference spawn, the random-path pin.
	"seed_choice": [preload("res://scripts/app/seed_choice_scenario.gd"), "run", []],
	# Title-flow gate: splash -> title -> creation (seed/shiny/name/avatar/GO) driven
	# through the real screens — world + persistence witnesses (checks split into
	# new_game_flow_checks.gd for the app budget; self-pinned, NOT a double-run consumer).
	"new_game_flow": [preload("res://scripts/app/new_game_flow_scenario.gd"), "run", []],
	"visual_sweep_world_depth": [preload("res://scripts/app/visual_sweep_world_depth.gd"), "run_sweep", []],
	"visual_sweep_world_depth_update": [preload("res://scripts/app/visual_sweep_world_depth.gd"), "run_sweep", [{"mode": "update"}]],
	# Far-field infinite-world sweep (shots 42-43, seed 2026072908): distant scatter + lair.
	"visual_sweep_farfield": [preload("res://scripts/app/visual_sweep_farfield.gd"), "run_sweep", []],
	"visual_sweep_farfield_update": [preload("res://scripts/app/visual_sweep_farfield.gd"), "run_sweep", [{"mode": "update"}]],
	# Bounded temporal capture (battle attack/capture adapters) — windowed-only.
	"temporal_flow": [preload("res://scripts/app/temporal_flow_scenario.gd"), "run", []],
	# Live-play drive for tools/commandcode_play_agent.py — windowed-only like
	# temporal_flow; runs inside the dispatcher's save backup/restore guard.
	"play_agent": [preload("res://scripts/app/play_agent_scenario.gd"), "run", []],
	# Showcase capture (NOT a baseline sweep): crafts the coolest locales deterministically and saves
	# evocative frames + crafted-state sidecars to docs/generated/showcase/. Deliberately outside the
	# baseline gate machinery — no SHOT_REGISTRY entry, no reconcile()/region-diff gate. Windowed-only.
	"showcase_capture": [preload("res://scripts/app/showcase_capture_scenario.gd"), "run", []],
}


static func handles(scenario: String) -> bool:
	return SCENARIOS.has(scenario)


static func run(scenario: String, host: Node, ctx: Dictionary) -> void:
	var entry: Array = SCENARIOS[scenario]
	var node: Node = (entry[0] as Script).new()
	host.add_child(node)
	var args: Array = [ctx]
	args.append_array(entry[2])
	await node.callv(entry[1], args)
