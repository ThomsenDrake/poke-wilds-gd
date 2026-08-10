extends Node

# Agent-legibility custom Performance monitors (agent-neutral integration
# Phase 2; docs/references/agent-integration.md): game/party_size,
# game/world_seed, and game/current_screen, queryable via
# Performance.get_custom_monitor even in RELEASE builds (the JSONL trace is a
# file artifact; these are the live-probe surface). ONE self-registering child
# of GameRuntime, added in _ready beside the other setup() calls —
# game_runtime.gd is AT its 320 budget (the registry's extraction-first rule),
# so registration + value reads live here and the runtime gains only the one
# add_child line. game/current_screen's screen ids are MANUALLY kept in sync
# with the ui_tree_dump scenario's screen ids
# (scripts/app/ui_tree_dump_scenario.gd) — nothing constructs the agreement.

# Godot teardown quirk: at engine cleanup the Performance singleton destroys
# its monitor callables AFTER the GameRuntime autoload's script is gone —
# lambda callables segfault there (Godot 4.6.1, reproduced headless). Plain
# method Callables on this child destroy cleanly; _exit_tree REMOVES the
# monitors (the engine refuses remove AFTER its own destruction pass starts —
# the normal quit path frees this child first, so removal always lands in
# time).

func _ready() -> void:
	name = "PerformanceMonitors"
	Performance.add_custom_monitor(&"game/party_size", Callable(self, "party_size"))
	Performance.add_custom_monitor(&"game/world_seed", Callable(self, "world_seed"))
	Performance.add_custom_monitor(&"game/current_screen", Callable(self, "screen_label"))


func _exit_tree() -> void:
	Performance.remove_custom_monitor(&"game/party_size")
	Performance.remove_custom_monitor(&"game/world_seed")
	Performance.remove_custom_monitor(&"game/current_screen")


func party_size() -> int:
	return (get_parent() as Node).session.party.size()


func world_seed() -> int:
	return (get_parent() as Node).session.world_seed


func screen_label() -> String:
	return screen_label_for(get_parent())


# The visible UI root's screen id; "boot" until the Main scene's UI node
# exists, "overworld" when no screen is up. Submenus (party/bag) shadow the
# start menu; creation/title/battle are exclusive phases. Defensive lookups
# throughout: this is a diagnostics surface, so a Main.tscn rename must
# degrade to "unknown", never hard-error.
static func screen_label_for(runtime: Node) -> String:
	var ui := runtime.get_node_or_null("/root/Main/UI")
	if ui == null: return "boot"
	var title := ui.get_node_or_null("TitleScreen")
	var creation := ui.get_node_or_null("CreationScreen")
	var battle := ui.get_node_or_null("BattleView")
	var menu := ui.get_node_or_null("StartMenu")
	if title == null or creation == null or battle == null or menu == null: return "unknown"
	if title.visible: return "title"
	if creation.visible: return "creation"
	if battle.visible: return "battle"
	var party := menu.get_node_or_null("PartyScreen")
	var bag := menu.get_node_or_null("BagScreen")
	if party == null or bag == null: return "unknown"
	if party.visible: return "party"
	if bag.visible: return "bag"
	if menu.visible: return "menu"
	return "overworld"
