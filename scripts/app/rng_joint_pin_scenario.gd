extends Node

# RNG JOINT PIN (pre-Phase-7 determinism lane): encounter draws + fishing casts share
# game_runtime._rng (fishing_runtime rides the injected stream, NEVER a private seed),
# and harvest dig steps are STEP-PURE (the dig bonus is a step-counter draw, NO rng).
# Under ONE seed_for_smoke seed the scenario drives the consumers' real entry points
# in a fixed interleaving — cast, encounter draw, dig, repeated — TWICE in-scenario
# (a seeded new_game per run resets bag/party/world, so the runs are state-identical)
# and byte-compares the exact species/item sequence as canonical JSON. Any consumption-
# order drift between the consumers flips the pin. A hooked mon riding the pending seam
# into the NEXT encounter draw is part of the pinned joint behavior (the fishing
# precedent at game_runtime.generate_wild_encounter). miss-002: symmetric markers,
# every red names its cause.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")

const SEED := 2026072803 # the joint pin (distinct from every other scenario seed)
const CYCLES := 12 # casts + draws + digs per run
const WATER_SCAN := 60
const ENCOUNTER_SCAN := 40
const DIG_SCAN := 40

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _reasons: Array = []


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	var player := _player()
	var saved_chance: float = player.encounter_chance
	player.encounter_chance = 0.0 # the avatar trigger stream is pinned too, but never fires in-scenario
	var first: Dictionary = _run_once(runtime)
	var second: Dictionary = _run_once(runtime)
	player.encounter_chance = saved_chance
	_ensure(bool(first.get("water", false)), "no water tile within %d rings of the pinned spawn" % WATER_SCAN)
	_ensure(bool(first.get("grass", false)), "no encounter tile within %d rings of the pinned spawn" % ENCOUNTER_SCAN)
	_ensure(bool(first.get("dig", false)), "no dig tile within %d rings of the pinned spawn" % DIG_SCAN)
	var seq_a: Array = first.get("seq", [])
	var seq_b: Array = second.get("seq", [])
	_ensure(not seq_a.is_empty(), "the interleaving produced no draws")
	for entry in seq_a:
		if (entry as Array)[0] == "enc" and str((entry as Array)[1]).is_empty():
			_ensure(false, "an encounter draw came back species-empty")
			break
	var canon_a := JSON.stringify(seq_a)
	var canon_b := JSON.stringify(seq_b)
	_ensure(canon_a == canon_b, "the joint sequence drifted between two runs under the same seed")
	var digest: int = abs(canon_a.hash())
	if _reasons.is_empty():
		runtime.emit_trace("rng_joint_pin_passed", "SmokeScenarios", {"seed": SEED, "cycles": CYCLES,
			"draws": seq_a.size(), "hooks": int(first.get("hooks", 0)), "digest": digest})
	else:
		runtime.emit_trace("rng_joint_pin_failed", "SmokeScenarios", {"seed": SEED, "reasons": _reasons,
			"digest_a": abs(canon_a.hash()), "digest_b": abs(canon_b.hash())})
		push_error("RngJointPinScenario failed: %s" % "; ".join(PackedStringArray(_reasons)))
		runtime.warn("RngJointPinScenario", "Joint rng pin failed.", {"reasons": _reasons})


# One run: seed BEFORE new_game (the world-seed draw rides _rng too), re-grant the rod +
# the all-field-moves party, rediscover the tiles (a pure function of the pinned world),
# then drive the fixed interleaving over the consumers' public entry points.
func _run_once(runtime) -> Dictionary:
	runtime.seed_for_smoke(SEED)
	runtime.new_game()
	runtime.session.add_item("old_rod", 1)
	_runner.swap_party(runtime, FieldMovesParty.FIELD_MOVES_PARTY, FieldMovesParty.PARTY_LEVEL)
	var center: Vector2i = runtime.session.player_tile
	var water: Dictionary = _find_water(center)
	var grass: Vector2i = _find_encounter_tile(center)
	var dig: Dictionary = _runner.find_harvest_target(_world(), center, DIG_SCAN, "dig")
	var seq: Array = []
	var hooks := 0
	if not water.is_empty():
		_runner.teleport_player(_world(), _player(), runtime, water["stand"])
	for _cycle in range(CYCLES):
		var cast: Dictionary = runtime.fishing_runtime.try_fish(water["tile"]) if not water.is_empty() else {}
		var hooked := bool(cast.get("ok", false))
		if hooked:
			hooks += 1
		seq.append(["cast", hooked, str(cast.get("reason", ""))])
		if grass != Vector2i.ZERO:
			var enc: Dictionary = runtime.generate_wild_encounter(grass, _world().get_tile_biome(grass))
			seq.append(["enc", str(enc.get("species_id", "")), int(enc.get("level", 0))])
		if not dig.is_empty():
			var found: Dictionary = runtime.harvest_tile(dig["tile"])
			seq.append(["dig", str(found.get("action", "")), str(found.get("item_id", ""))])
	return {"seq": seq, "hooks": hooks, "water": not water.is_empty(), "grass": grass != Vector2i.ZERO, "dig": not dig.is_empty()}


# Nearest WATER-biome tile with a walkable stand (the fishing satellite's ring-scan shape).
func _find_water(center: Vector2i) -> Dictionary:
	for radius in range(2, WATER_SCAN):
		for tile in _runner.ring_around(center, radius):
			if _world().get_tile_biome(tile) != "WATER":
				continue
			for offset in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
				if _world().is_tile_walkable(tile + offset):
					return {"tile": tile, "stand": tile + offset}
	return {}


func _find_encounter_tile(center: Vector2i) -> Vector2i:
	for radius in range(1, ENCOUNTER_SCAN):
		for tile in _runner.ring_around(center, radius):
			if _world().is_encounter_tile(tile):
				return tile
	return Vector2i.ZERO


func _ensure(ok: bool, reason: String) -> bool:
	if not ok:
		_reasons.append(reason)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
