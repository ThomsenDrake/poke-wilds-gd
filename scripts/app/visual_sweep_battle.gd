extends Node

# Battle shots 09-12 of the main visual sweep (extracted from visual_sweep.gd +
# visual_sweep_baselines.gd for the app line budget). Forces a fixed wild species
# (DECIDUEYE's 13-frame strip front.png is the sprite-loader regression canary) and
# reseeds the battle RNG so damage rolls, move picks, and messages are reproducible.
# Driven through the main sweep's own _capture callable so metadata + failure
# bookkeeping stay single-sourced there.

const BATTLE_SHOTS := ["09_battle.png", "10_battle_moves.png", "11_battle_after_attack.png", "12_battle_items.png"]

var _ctx: Dictionary = {}
var _crafted: Dictionary = {}
var _capture: Callable = Callable()
var _failures: Array = []


func craft_battle(ctx: Dictionary, crafted: Dictionary, capture: Callable, failures: Array) -> void:
	_ctx = ctx
	_crafted = crafted
	_capture = capture
	_failures = failures
	if not _start_battle():
		for shot in BATTLE_SHOTS:
			_failures.append("%s: could not start a wild battle" % shot)
		return
	var view := _battle_view()
	await _capture.call("09_battle.png")
	view._set_menu_state("action")
	view._selection = "fight"
	view._activate_selection()
	await _capture.call("10_battle_moves.png")
	view._selection = _damaging_move_id(_runtime())
	view._activate_selection()
	await _await_battle_idle(view)
	await _capture.call("11_battle_after_attack.png")
	if not view.visible and not _start_battle():
		_failures.append("12_battle_items.png: battle ended and no new battle could start")
		return
	await _await_battle_idle(view)
	view._set_menu_state("action")
	view._selection = "item"
	view._activate_selection()
	await _capture.call("12_battle_items.png")
	if view.visible:
		view.run_smoke_escape()
		for _i in range(2):
			await get_tree().process_frame


# Forces the fixed wild species and reseeds the battle RNG (crafted["battle_rng_seed"]).
func _start_battle() -> bool:
	var runtime = _runtime()
	runtime.battle_runtime._rng.seed = int(_crafted.get("battle_rng_seed", 0))
	var wild: Array = _crafted.get("wild", [])
	var entry: Dictionary = runtime.catalog.get_species(str(wild[0])) if wild.size() == 2 else {}
	if entry.is_empty():
		return false
	var wild_mon = runtime.pokemon_rules.create_pokemon_instance(entry, int(wild[1]), Callable(runtime.catalog, "get_move"))
	if wild_mon.is_empty():
		return false
	var set_battle: Callable = _ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.callv([true])
	_message_box().hide_message()
	var music: Object = _ctx.get("music_router")
	if music != null:
		music.play_battle_track("wild")
	_battle_view().start_wild_battle(wild_mon)
	return _battle_view().visible


# First lead-party move with power and PP left; falls back to the first slot.
func _damaging_move_id(runtime) -> String:
	var party: Array = runtime.get_party_snapshot()
	if not party.is_empty():
		var moves: Array = party[0].get("moves", [])
		for i in range(moves.size()):
			var move: Dictionary = moves[i]
			if int(move.get("power", 0)) > 0 and int(move.get("pp", 0)) > 0:
				return "move_%d" % i
	return "move_0"


func _await_battle_idle(view: Node) -> void:
	for _i in range(240):
		if not view.visible or not view.is_animating():
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _runtime() -> Node: return _ctx["runtime"]
func _battle_view() -> Node: return _ctx["battle_view"]
func _message_box() -> Node: return _ctx["message_box"]
