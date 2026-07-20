extends Node

# Harvest-flow scenario (plan Task 6: docs/superpowers/plans/
# 2026-07-18-harvest-and-world-mutation.md). Drives the full harvest loop
# against the live scene through the same entry point context-Z and the party
# screen use (game_runtime.harvest_tile on the faced tile):
#   (a) no-capability party (magikarp) -> refusal carrying the block hint;
#   (b) capable party (bulbasaur + geodude for dig/smash) -> cut yields a log
#       and the tree tile turns walkable and prop-less with NO world rebuild
#       (the runtime's world_overridden signal refreshes the view in place);
#   (c) dig PLAINS ground -> dry_soil plus dug semantics (encounter/tall
#       grass off; PLAINS grows no tall grass per biome_defs.gd, so the
#       tall-grass assertion is the post-dig invariant itself);
#   (d) smash a rock -> hard_stone;
#   (e) save, reload via save_store.load_payload + the runtime apply path,
#       rebuild: all three tiles still read cleared/dug.
# Party crafting uses direct session writes via the runner's swap_party /
# restore_party rather than visual_sweep_baselines' full-payload craft: that
# path resets bag/clock/steps and never re-seeds the runtime generator, which
# harvesting depends on. Save backup/restore is the dispatcher's job.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")

const SCAN_RADIUS := 40

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	var cut := _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, "cut")
	var dig := _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, "dig", "PLAINS")
	var smash := _runner.find_harvest_target(_world(), _player().tile_position, SCAN_RADIUS, "smash")
	if cut.is_empty() or dig.is_empty() or smash.is_empty():
		_failures.append("targets: no cut/dig/smash tile within %d rings" % SCAN_RADIUS)
	else:
		var party_before: Array = _runner.swap_party(_runtime(), ["MAGIKARP"])
		_check_refusal(cut)
		_runner.swap_party(_runtime(), ["BULBASAUR", "GEODUDE"])
		_check_cut(cut)
		_check_dig(dig)
		_check_smash(smash)
		_runner.restore_party(_runtime(), party_before)
		var save_ok := _check_save_roundtrip([cut["tile"], dig["tile"], smash["tile"]])
		if _failures.is_empty():
			_runtime().emit_trace("harvest_flow_passed", "SmokeScenarios", {
				"cut_tile": [cut["tile"].x, cut["tile"].y],
				"dig_tile": [dig["tile"].x, dig["tile"].y],
				"smash_tile": [smash["tile"].x, smash["tile"].y],
				"save_ok": save_ok
			})
	_player().encounter_chance = saved_chance
	if not _failures.is_empty():
		_runtime().warn("HarvestFlowScenario", "Harvest flow failed: %s." % "; ".join(PackedStringArray(_failures)), {})


# (a) A party with no cut/dig/smash capability is refused with the hint.
func _check_refusal(cut: Dictionary) -> void:
	_face_target(cut)
	var result: Dictionary = _runtime().harvest_tile(_player().facing_tile())
	if bool(result.get("ok", true)):
		_failures.append("refusal: no-capability party harvested the tree")
	elif not str(result.get("message", "")).contains("It could be CUT."):
		_failures.append("refusal: message carried no CUT hint (%s)" % str(result.get("message", "")))


# (b) Context action cuts the faced tree: one log, the cut trace, and the tile
# walkable + prop-less in place (no rebuild — the world_overridden signal).
func _check_cut(cut: Dictionary) -> void:
	if not _failures.is_empty():
		return
	var tile: Vector2i = cut["tile"]
	_face_target(cut)
	var logs_before: int = _runtime().get_item_count("log")
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = _runtime().harvest_tile(_player().facing_tile())
	if not bool(result.get("ok", false)) or str(result.get("yield_item", "")) != "log":
		_failures.append("cut: resolver refused or yielded wrong (%s)" % str(result))
	elif _runtime().get_item_count("log") != logs_before + 1:
		_failures.append("cut: bag did not gain exactly one log")
	elif not _runner.trace_log_has_since("field_move_used", cursor, {"move_id": "cut", "tile": [tile.x, tile.y], "yield": "log"}):
		_failures.append("cut: no field_move_used trace with the cut payload")
	elif not _world().is_tile_walkable(tile) or _world().get_tile_prop_texture(tile) != null:
		_failures.append("cut: tile not walkable and prop-less without a rebuild")


# (c) Dig walkable PLAINS ground: dry_soil yield, dug semantics. The tile is
# walkable, so facing cannot be set by a blocked step; the resolver gets the
# explicit tile (same entry point context-Z resolves to).
func _check_dig(dig: Dictionary) -> void:
	if not _failures.is_empty():
		return
	var tile: Vector2i = dig["tile"]
	_runner.teleport_player(_world(), _player(), _runtime(), dig["from_tile"])
	var soil_before: int = _runtime().get_item_count("dry_soil")
	var result: Dictionary = _runtime().harvest_tile(tile)
	if not bool(result.get("ok", false)) or str(result.get("yield_item", "")) != "dry_soil":
		_failures.append("dig: resolver refused or yielded wrong (%s)" % str(result))
	elif _runtime().get_item_count("dry_soil") != soil_before + 1:
		_failures.append("dig: bag did not gain exactly one dry_soil")
	else:
		var logic: Dictionary = _world().get_tile_logic(tile)
		if not bool(logic.get("mutated", false)) or not bool(logic.get("walkable", false)):
			_failures.append("dig: tile not mutated-walkable after digging")
		elif bool(logic.get("encounter", true)) or not str(logic.get("tall_grass_path", "x")).is_empty():
			_failures.append("dig: dug tile kept its encounter or tall grass")


# (d) Smash a rock: one hard_stone; tile cleared like the cut tile.
func _check_smash(smash: Dictionary) -> void:
	if not _failures.is_empty():
		return
	var tile: Vector2i = smash["tile"]
	_face_target(smash)
	var stones_before: int = _runtime().get_item_count("hard_stone")
	var result: Dictionary = _runtime().harvest_tile(_player().facing_tile())
	if not bool(result.get("ok", false)) or str(result.get("yield_item", "")) != "hard_stone":
		_failures.append("smash: resolver refused or yielded wrong (%s)" % str(result))
	elif _runtime().get_item_count("hard_stone") != stones_before + 1:
		_failures.append("smash: bag did not gain exactly one hard_stone")
	elif not _world().is_tile_walkable(tile) or _world().get_tile_prop_texture(tile) != null:
		_failures.append("smash: tile not walkable and prop-less without a rebuild")


# (e) Save, reload via save_store.load_payload + the runtime apply path, then
# rebuild the view: every harvested tile must still read mutated and walkable
# and render no prop. Returns false (after recording failures) when the
# round-trip lost anything.
func _check_save_roundtrip(tiles: Array) -> bool:
	if not _failures.is_empty():
		return false
	_runtime().save_game()
	var payload: Dictionary = _runtime().save_store.load_payload()
	var saved: Dictionary = payload.get("world_overrides", {})
	for tile in tiles:
		if not saved.has("%d,%d" % [tile.x, tile.y]):
			_failures.append("save: %s missing from world_overrides" % str(tile))
	if not _failures.is_empty():
		return false
	_runtime()._apply_loaded_payload(payload)
	_world().rebuild(_runtime().get_world_seed())
	var ok := int(payload.get("version", 0)) == SessionState.SAVE_VERSION
	for tile in tiles:
		_world().sync_visible(tile)
		var logic: Dictionary = _world().get_tile_logic(tile)
		if not bool(logic.get("mutated", false)) or not _world().is_tile_walkable(tile) or _world().get_tile_prop_texture(tile) != null:
			_failures.append("save: %s did not stay cleared after the reload" % str(tile))
			ok = false
	return ok


# Teleports to the target's stand tile and steps toward it; the step is
# rejected (tree/rock props block) but still turns the avatar to face it.
func _face_target(target: Dictionary) -> void:
	_runner.teleport_player(_world(), _player(), _runtime(), target["from_tile"])
	_player().smoke_step(target["direction"])


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
