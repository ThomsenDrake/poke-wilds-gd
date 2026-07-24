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
	# Phase 2 camping / crafting / night-survival proofs (camping-crafting-survival.md);
	# like every non-playtest entry, they run inside smoke_scenarios' save guard.
	"camp_survival": [preload("res://scripts/app/camp_survival_scenario.gd"), "run", []],
	"craft_flow": [preload("res://scripts/app/craft_flow_scenario.gd"), "run", []],
	"night_cycle": [preload("res://scripts/app/night_cycle_scenario.gd"), "run", []],
	"time_evolution": [preload("res://scripts/app/time_evolution_scenario.gd"), "run", []],
	"visual_sweep": [preload("res://scripts/app/visual_sweep.gd"), "run_sweep", []],
	"visual_sweep_update": [preload("res://scripts/app/visual_sweep.gd"), "run_sweep", [{"mode": "update"}]],
	"visual_sweep_camping": [preload("res://scripts/app/visual_sweep_camping.gd"), "run_sweep", []],
	"visual_sweep_camping_update": [preload("res://scripts/app/visual_sweep_camping.gd"), "run_sweep", [{"mode": "update"}]],
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
