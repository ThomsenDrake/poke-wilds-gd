extends Node

# battle_anim scenario: proves the attack-animation wave end-to-end. The party
# lead is rebuilt as a Charmander (learns EMBER at Lv.4; ember_player_gsc is
# one of the source animation sets) and the wild side as a same-level Geodude
# (rock resist keeps EMBER from ending the battle before it animates). The
# scenario drives the live battle view's menu handlers like nav_audit does,
# waits out the async playback (hard-capped), then asserts from the trace log:
# an attack_animation_played event for EMBER with frames > 0 and sound = true,
# plus a resolved turn (enemy HP changed or the battle text names the move).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const TRACE_LOG_PATH := "user://logs/agent_trace.jsonl"
const MAX_ANIM_WAIT_SECONDS := 8.0

var _runner = SmokeScenarioRunner.new()


func run(ctx: Dictionary) -> void:
	await get_tree().create_timer(0.2).timeout
	var fail := await _drive(ctx)
	var runtime: Node = ctx["runtime"]
	if fail.is_empty():
		runtime.emit_trace("battle_anim_passed", "SmokeScenarios", {})
	else:
		runtime.warn("SmokeScenarios", "battle_anim scenario failed: %s." % fail, {})
	await get_tree().create_timer(0.2).timeout


func _drive(ctx: Dictionary) -> String:
	var runtime: Node = ctx["runtime"]
	var catalog = runtime.get("catalog")
	var pokemon_rules = runtime.get("pokemon_rules")
	if catalog == null or pokemon_rules == null:
		return "runtime did not expose catalog/pokemon_rules"
	var get_move := Callable(catalog, "get_move")
	var lead: Dictionary = pokemon_rules.create_pokemon_instance(catalog.get_species("CHARMANDER"), 10, get_move)
	var ember_index := _move_index(lead, "EMBER")
	if ember_index < 0:
		return "built Charmander does not know EMBER"
	var wild_mon: Dictionary = pokemon_rules.create_pokemon_instance(catalog.get_species("GEODUDE"), 12, get_move)
	if wild_mon.is_empty():
		return "could not build wild Geodude"
	var party_index: int = runtime.get("session").get_active_party_index()
	if party_index < 0:
		return "no active party slot for the rebuilt lead"
	runtime.get("session").set_party_member(party_index, lead)

	var cursor: int = _runner.trace_log_line_count()
	var set_battle: Callable = ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(true)
	ctx["message_box"].hide_message()
	ctx["music_router"].play_battle_track("wild")
	var view: Node = ctx["battle_view"]
	view.start_wild_battle(wild_mon)
	if not view.visible:
		return "battle view did not open"
	var enemy_hp_before := int(view._snapshot.get("enemy_mon", {}).get("current_hp", 0))
	view._set_menu_state("moves")
	view._selection = "move_%d" % ember_index
	view._activate_selection()

	var waited := 0.0
	while view.is_animating() and waited < MAX_ANIM_WAIT_SECONDS:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	if view.is_animating():
		return "animation playback never finished"

	var anim_trace := _anim_trace_since(cursor)
	if anim_trace.is_empty():
		return "no attack_animation_played trace for EMBER"
	if int(anim_trace.get("frames", 0)) <= 0:
		return "attack_animation_played reported zero frames"
	if not bool(anim_trace.get("sound", false)):
		return "attack_animation_played reported no sound"
	var enemy_hp_after := int(view._snapshot.get("enemy_mon", {}).get("current_hp", 0))
	if enemy_hp_after == enemy_hp_before and not str(view._message).to_upper().contains("EMBER"):
		return "turn did not resolve (enemy HP unchanged, no EMBER battle text)"
	if set_battle.is_valid():
		set_battle.call(false)
	return ""


func _move_index(mon: Dictionary, move_id: String) -> int:
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		if str(moves[i].get("move_id", "")) == move_id:
			return i
	return -1


func _anim_trace_since(from_line: int) -> Dictionary:
	if not FileAccess.file_exists(TRACE_LOG_PATH):
		return {}
	var file := FileAccess.open(TRACE_LOG_PATH, FileAccess.READ)
	if file == null:
		return {}
	var line_index := 0
	var found := {}
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		line_index += 1
		if line_index <= from_line or not line.begins_with("{"):
			continue
		var parsed = JSON.parse_string(line)
		if parsed is Dictionary and str(parsed.get("event", "")) == "attack_animation_played":
			var payload = parsed.get("payload", {})
			if payload is Dictionary and str(payload.get("move_id", "")) == "EMBER":
				found = payload
	file.close()
	return found
