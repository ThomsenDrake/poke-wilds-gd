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
	"visual_sweep_overworld": [preload("res://scripts/app/visual_sweep_overworld.gd"), "run_sweep", []],
	"visual_sweep_overworld_update": [preload("res://scripts/app/visual_sweep_overworld.gd"), "run_sweep", [{"mode": "update"}]],
	# Pokemon-state shots 20-21 (shared baseline dir; update never prunes foreign shots).
	"visual_sweep_pokemon": [preload("res://scripts/app/visual_sweep_pokemon.gd"), "run_sweep", []],
	"visual_sweep_pokemon_update": [preload("res://scripts/app/visual_sweep_pokemon.gd"), "run_sweep", [{"mode": "update"}]],
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
