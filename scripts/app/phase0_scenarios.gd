extends Node

# Phase-0 defect-fix scenarios (qa_scenarios pattern) inside the runner's save
# backup/restore guard. wild_battle lives in wild_battle_scenario.gd and save_migration
# lives in save_migration_scenario.gd (both EXTRACTED for the v4/v6 fixture work + the app
# line budget). save_migration covers v1/v2->v3->v4->v5->v6 — see that file's header for
# the full fixture matrix (v3 "structures", v4 "contents"/"pastures", v5 CHAIN-LESS -> v6
# lossless flatten + the CHAINED-v5 REFUSAL witness, future refusal, corrupt recovery).

const WildBattleScenario := preload("res://scripts/app/wild_battle_scenario.gd")
const SaveMigrationScenario := preload("res://scripts/app/save_migration_scenario.gd")

const SCENARIOS := {"wild_battle": "run_wild_battle", "save_migration": "run_save_migration"}

static func handles(scenario: String) -> bool:
	return SCENARIOS.has(scenario)

static func run(scenario: String, host: Node, ctx: Dictionary) -> void:
	var node: Node = (load("res://scripts/app/phase0_scenarios.gd") as Script).new()
	host.add_child(node)
	await node.call(SCENARIOS[scenario], ctx, host)

func run_wild_battle(ctx: Dictionary, host: Node) -> void:
	var node: Node = WildBattleScenario.new()
	host.add_child(node) # the scenario reaches the host's _run_smoke_battle via get_parent()
	await node.run(ctx)

func run_save_migration(ctx: Dictionary, host: Node) -> void:
	var node: Node = SaveMigrationScenario.new()
	host.add_child(node)
	await node.run(ctx, host)
