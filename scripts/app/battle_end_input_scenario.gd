extends Node

# Battle-END same-press leak regression (the generalized latch's battle arm;
# spec: the Input map in bootstrap-and-overworld.md). input_router.gd's
# _ui_ate_press latch (bind_ui_consumers) closed the FOUR menu same-press leaks
# (input_gate parts A/B + input_gate_menu_checks C/E/D), but a press that ENDS
# A BATTLE still re-fired the overworld context action the same frame:
# battle_view._unhandled_input (input phase) Z-on-RUN resolves run_from_battle
# SYNCHRONOUSLY -> battle_finished -> main._on_battle_finished sets _in_battle
# = false + re-enables the avatar WITHIN the input phase -> the same-frame
# Main._process poll_context_action sees overworld_idle + action_a just_pressed
# and harvests/builds the faced tile (the harvest toast supersedes "Got away
# safely!"). A ball-select Z capture is the same class (use_pokeball resolving
# synchronously). The fix sets the SAME latch from _on_battle_finished (every
# end path: RUN, capture, victory, defeat), consumed + reset by
# poll_context_action exactly like the menu paths. This scenario drives REAL
# input-phase events — never direct runtime calls — like input_gate: (A) Z on
# RUN facing a cut-harvestable tile escapes ONLY (no field_move_used /
# structure_placed / materials_consumed, the tree stands, the escape toast
# survives, the bag is unchanged); (B) a fresh DELIBERATE Z next frame still
# harvests (poll_context_action resets the latch unconditionally, so the fix
# never over-suppresses); (C) a ball-select Z on a guaranteed-capture mon
# captures ONLY (the tree stands, the "Gotcha!" toast survives). Injection:
# Input.use_accumulated_input buffers each parsed event for the NEXT
# iteration's input phase — _unhandled_input first, then same-iteration polls
# with just_pressed true (the bug frame); press and release land in SEPARATE
# iterations via smoke_tap.gd (smoke _press injects press+release in one frame
# and can never fire a poll); every tap carries an INJECTION WITNESS so
# degraded delivery fails red, never vacuous.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SmokeTap := preload("res://scripts/app/smoke_tap.gd")
const HarvestResolver := preload("res://scripts/runtime/harvest_resolver.gd")
const BattleScenarioFixtures := preload("res://scripts/app/battle_scenario_fixtures.gd")

const SEED := 2026072402

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	Input.use_accumulated_input = true
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	# Self-contained pinned world (the breed_flow precedent): the boot-save chain's
	# leftover tile flaked the site scans (2026-08-09 S7 red); game_reset is menu-only.
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed())
	_runner.resync_player_tile(_world(), _player(), runtime)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var party_before: Array = _runner.swap_party(runtime, ["BULBASAUR"]) # cut-capable, so a re-fire fells the tree LOUDLY
	_expect(runtime.party_has_field_move_ability("cut"), "precondition: swapped party is not cut-capable (the re-fire branch would be dead)")
	var cut_tile := _face_cut_tile(_player().tile_position)
	if cut_tile != Vector2i.ZERO and _failures.is_empty():
		await _part_a_escape_does_not_refire(cut_tile)
		await _part_b_deliberate_press_still_harvests(cut_tile)
		var cut_tile_two := _face_cut_tile(_player().tile_position)
		if _expect(cut_tile_two != Vector2i.ZERO, "site: no second cut tile with a stand spot within 40 rings"):
			await _part_c_capture_does_not_refire(cut_tile_two)
	if _failures.is_empty():
		runtime.emit_trace("battle_end_input_passed", "SmokeScenarios", {"escape_no_refire": true, "deliberate_press_harvests": true, "capture_no_refire": true, "seed": SEED})
	else:
		runtime.emit_trace("battle_end_input_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		runtime.warn("BattleEndInputScenario", "Battle-end input gate failed: %s." % "; ".join(PackedStringArray(_failures)), {})
		push_error("Battle-end input gate failed: %s" % "; ".join(PackedStringArray(_failures)))
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance
	_runner.resync_player_tile(_world(), _player(), runtime)
	_set_battle(false)
	Input.use_accumulated_input = false


# Stands the player on a fresh cut tree's walkable neighbor facing it (a blocked step still turns — field_move precedent).
func _face_cut_tile(center: Vector2i) -> Vector2i:
	var found: Dictionary = _runner.find_harvest_target(_world(), center, 40, "cut")
	if found.is_empty():
		_failures.append("site: no cut-harvestable tile with a stand spot within 40 rings")
		return Vector2i.ZERO
	_runner.teleport_player(_world(), _player(), _runtime(), found["from_tile"])
	_player().smoke_step(found["direction"]) # blocked by the tree, but faces it
	_expect(_player().facing_tile() == found["tile"], "site: the player does not face the cut tile after the blocked step")
	return found["tile"]


# Part A — the press that ends the battle on RUN escapes ONLY; the same-frame poll must not fire.
func _part_a_escape_does_not_refire(cut_tile: Vector2i) -> void:
	var runtime = _runtime()
	var player = _player()
	_start_battle(_wild_mon(runtime))
	if not _expect(_battle_view().visible, "A: injection witness: the scripted battle did not open"):
		return
	await _select("run")
	if not _expect(str(_battle_view().get("_selection")) == "run", "A: precondition witness: RUN is not selected"):
		return
	var tile_before: Vector2i = player.tile_position
	var bag_before: Dictionary = runtime.session.bag.duplicate(true)
	var cursor: int = _runner.trace_log_line_count()
	await _tap("action_a") # the race frame: the input phase ends the battle on RUN; the poll must be swallowed
	_expect(not _battle_view().visible, "A: injection witness: Z-on-RUN did not end the battle")
	_expect(_runner.trace_log_has_since("battle_finished", cursor, {"outcome": "escaped"}), "A: injection witness: no escaped outcome traced")
	_expect(_toast_text() == "Got away safely!", "A: the escape toast '%s' was superseded by a re-fired context action" % _toast_text())
	_expect(not _runner.trace_log_has_since("field_move_used", cursor), "A: a harvest re-fired on the faced tile on the escape frame")
	_expect(not _runner.trace_log_has_since("structure_placed", cursor), "A: a structure was placed on the re-fired press")
	_expect(not _runner.trace_log_has_since("materials_consumed", cursor), "A: materials were consumed on the re-fired press")
	_expect(not _structure_layer().is_active(), "A: build mode opened on the escape frame")
	_expect(_tree_stands(cut_tile), "A: the faced tree fell on the escape frame")
	_expect(runtime.session.bag == bag_before, "A: the bag changed on the escape frame (a harvest yield leaked)")
	_expect(player.tile_position == tile_before, "A: the player moved")
	_expect(player.input_enabled, "A: the avatar stayed disabled after the battle ended")


# Part B — a fresh deliberate Z next frame STILL harvests (the latch must never over-suppress past the battle-end frame).
func _part_b_deliberate_press_still_harvests(cut_tile: Vector2i) -> void:
	var cursor: int = _runner.trace_log_line_count()
	await _tap("action_a") # a NEW press on a LATER frame: the context poll must fire
	_expect(_world().is_tile_walkable(cut_tile), "B: a fresh deliberate press did not harvest the faced tree")
	_expect(_runner.trace_log_has_since("field_move_used", cursor, {"move_id": "cut"}), "B: no field_move_used for the deliberate press (the latch suppresses past the battle-end frame)")


# Part C — the press that ends the battle on a ball-select Z captures ONLY.
func _part_c_capture_does_not_refire(cut_tile: Vector2i) -> void:
	var runtime = _runtime()
	var player = _player()
	runtime.session.add_item("poke_ball", 3)
	var target: Dictionary = BattleScenarioFixtures.guaranteed_capture_mon(runtime)
	if not _expect(not target.is_empty(), "C: precondition: no catalog species meets the guaranteed-capture catch rate"):
		return
	_start_battle(target)
	if not _expect(_battle_view().visible, "C: injection witness: the capture battle did not open"):
		return
	await _select("item")
	await _tap("action_a") # opens the item menu; the battle stays active, so the polls stay gated on _in_battle
	if not _expect(str(_battle_view().get("_selection")) == "poke_ball", "C: precondition witness: POKE BALL is not the item row (count %d)" % runtime.get_item_count("poke_ball")):
		return
	var tile_before: Vector2i = player.tile_position
	var cursor: int = _runner.trace_log_line_count()
	await _tap("action_a") # the race frame: the input phase resolves the capture; the poll must be swallowed
	_expect(not _battle_view().visible, "C: injection witness: Z-on-POKE-BALL did not end the battle")
	_expect(_runner.trace_log_has_since("battle_finished", cursor, {"outcome": "caught"}), "C: injection witness: no caught outcome traced")
	_expect(_toast_text().begins_with("Gotcha!"), "C: the capture toast '%s' was superseded by a re-fired context action" % _toast_text())
	_expect(not _runner.trace_log_has_since("field_move_used", cursor), "C: a harvest re-fired on the faced tile on the capture frame")
	_expect(not _runner.trace_log_has_since("structure_placed", cursor), "C: a structure was placed on the re-fired press")
	_expect(_tree_stands(cut_tile), "C: the faced tree fell on the capture frame")
	_expect(player.tile_position == tile_before, "C: the player moved")
	_expect(player.input_enabled, "C: the avatar stayed disabled after the battle ended")


# --- helpers ---
func _start_battle(wild_mon: Dictionary) -> void:
	if wild_mon.is_empty():
		_failures.append("battle: could not create the scripted wild encounter")
		return
	_set_battle(true)
	_message_box().hide_message()
	_battle_view().start_wild_battle(wild_mon)


# fight (0,0) -> item (0,1) on DOWN; item -> run (1,1) on RIGHT (battle_surface_layout's
# action grid). Every press is a REAL input-phase event the battle view consumes.
func _select(option: String) -> void:
	await _tap("move_down")
	if option == "run":
		await _tap("move_right")


func _wild_mon(runtime) -> Dictionary:
	var species_id := str(runtime.catalog.species.keys()[0])
	return runtime.pokemon_rules.create_pokemon_instance(runtime.catalog.get_species(species_id), 5, Callable(runtime.catalog, "get_move"))


func _tap(action: String) -> void:
	if not SmokeTap.inject_press(action):
		_failures.append("injection: no key event is bound to %s" % action)
		return
	await get_tree().process_frame
	SmokeTap.inject_release(action)
	await get_tree().process_frame


func _set_battle(active: bool) -> void:
	var callable: Callable = _ctx.get("set_battle", Callable())
	if callable.is_valid():
		callable.call(active)


# Faced cut target still stands (not harvested on the battle-end frame) — the dual of how
# _face_cut_tile picked it. NOT tile_requires_field_move: a standing cactus has field_move=""
# in biome_defs yet is cut-harvestable, so that read false-fails on cactus targets.
func _tree_stands(tile: Vector2i) -> bool:
	return HarvestResolver.action_for_tile(_world().get_tile_logic(tile)) == "cut"

func _expect(ok: bool, label: String) -> bool: # appends a labeled failure; returns ok for witness early-returns
	if not ok:
		_failures.append(label)
	return ok


func _toast_text() -> String:
	var label: Variant = _message_box().get("_label")
	return str((label as Label).text) if label is Label else ""


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _battle_view() -> Node: return _ctx["battle_view"]
func _message_box() -> Node: return _ctx["message_box"]
func _structure_layer() -> Node: return _ctx["structure_layer"]
