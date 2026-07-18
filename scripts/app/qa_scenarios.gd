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
	"visual_sweep": [preload("res://scripts/app/visual_sweep.gd"), "run_sweep", []],
	"visual_sweep_update": [preload("res://scripts/app/visual_sweep.gd"), "run_sweep", [{"mode": "update"}]],
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
