extends Node

# Camping survival scenario (Phase 2 camping slice; spec:
# docs/product-specs/camping-crafting-survival.md). Proves the rest / heal model
# and the campsite anchor end to end: (a) a sleeping-bag rest heals 50% HP and
# revives the fainted but does NOT cure status (rested{kind:"bag"}); (b) a placed
# bed (log x4 + soft_bedding) gives the full heal + status cure (rested{kind:"bed"});
# both rests ESTABLISH the campsite (campsite_tile = the rest tile, trace
# campsite_established); (c) a blackout returns the player to that campsite and
# explicitly NOT to the world origin; (d) campsite + bag survive a save round-trip.
# Deterministic: seed_for_smoke pins the stream, all state is set directly, and
# the dispatcher's save backup/restore guard keeps the real save untouched.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const SEED := 2026072301
const NIGHT_MINUTES := 1380 # 23:00 — deep in the night band (>= 1230)
const DAY_REST_MINUTES := 240
# Pinned mirror of day_phase.gd WAKE_MINUTES (the app layer may not import
# domain): a drift there turns this scenario's woke_at assert red, the point.
const WAKE_MINUTES := 420

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _rest_tile := Vector2i.ZERO


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	# BULBASAUR carries the damage/status for the heal asserts; MACHOP (FIGHTING)
	# makes the party Build-capable so the bed is placed without a party swap that
	# would wipe the crafted damage state.
	var party_before: Array = _runner.swap_party(runtime, ["BULBASAUR", "MACHOP"])
	var site := _find_rest_site(_player().tile_position)
	if site.is_empty():
		_failures.append("site: no open rest tile with a buildable neighbor within 8 rings")
	else:
		_rest_tile = site["rest"]
		_runner.teleport_player(_world(), _player(), runtime, _rest_tile)
		_check_bag_rest()
		_check_bed_rest(site["beds"] as Array)
		_check_blackout()
	var save_ok := _check_save_roundtrip()
	if _failures.is_empty():
		runtime.emit_trace("camp_survival_passed", "SmokeScenarios", {"bag_ok": true,
			"bed_ok": true, "blackout_ok": true, "campsite": [_rest_tile.x, _rest_tile.y], "save_ok": save_ok})
	else:
		runtime.emit_trace("camp_survival_failed", "SmokeScenarios", {"failures": _failures})
		runtime.warn("CampSurvivalScenario", "Camping survival failed: %s." % "; ".join(PackedStringArray(_failures)), {})
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance


# (a) Sleeping bag (bag_screen's Z routes HERE now; the scenario drives the
# runtime directly, house pattern): night rest heals 50% + revives, keeps PSN, lands at 07:00.
func _check_bag_rest() -> void:
	if not _failures.is_empty():
		return
	var session = _runtime().session
	_damage_party()
	session.time_of_day_minutes = NIGHT_MINUTES
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = _runtime().camping_runtime.rest("bag")
	if not bool(result.get("ok", false)):
		_failures.append("bag: rest refused (%s)" % str(result))
		return
	var hurt: Dictionary = session.get_party_member(0)
	var fainted: Dictionary = session.get_party_member(1)
	var hurt_expect := mini(int(hurt.get("max_hp", 1)), 1 + int(ceili(float(int(hurt.get("max_hp", 1))) * 0.5)))
	var revive_expect := mini(int(fainted.get("max_hp", 1)), int(ceili(float(int(fainted.get("max_hp", 1))) * 0.5)))
	if int(hurt.get("current_hp", 0)) != hurt_expect:
		_failures.append("bag: hurt mon healed to %d, not 1 + 50%% (%d)" % [int(hurt.get("current_hp", 0)), hurt_expect])
	if str(hurt.get("status", "")) != "PSN":
		_failures.append("bag: sleeping bag cured the PSN (it must not)")
	if int(fainted.get("current_hp", 0)) != revive_expect:
		_failures.append("bag: fainted mon revived to %d, not 50%% (%d)" % [int(fainted.get("current_hp", 0)), revive_expect])
	if int(result.get("woke_at", -1)) != WAKE_MINUTES:
		_failures.append("bag: night rest woke at %d, not %d" % [int(result.get("woke_at", -1)), WAKE_MINUTES])
	if session.campsite_tile != _rest_tile:
		_failures.append("bag: campsite_tile %s != rest tile %s" % [str(session.campsite_tile), str(_rest_tile)])
	if not _runner.trace_log_has_since("rested", cursor, {"kind": "bag"}):
		_failures.append("bag: no rested{kind:bag} trace")
	if not _runner.trace_log_has_since("campsite_established", cursor, {"tile": [_rest_tile.x, _rest_tile.y], "kind": "bag"}):
		_failures.append("bag: no campsite_established trace for the rest tile")


# (b) Bed: placed with the Build-capable MACHOP (log x4 + soft_bedding), then a
# bed rest fully heals BOTH members and cures the PSN the bag left behind.
func _check_bed_rest(bed_candidates: Array) -> void:
	if not _failures.is_empty():
		return
	var runtime = _runtime()
	var session = runtime.session
	session.add_item("log", 4)
	session.add_item("soft_bedding", 1)
	# The would-trap guard can refuse a candidate that would seal the player in;
	# the candidate list is every open neighbor, so the bed lands on the first
	# accepted tile (a refusal everywhere is a real failure).
	var placed: Dictionary = {"ok": false, "reason": "no_candidate"}
	for candidate in bed_candidates:
		placed = runtime.build_runtime.try_place(candidate as Vector2i, "bed", {})
		if bool(placed.get("ok", false)):
			break
	if not bool(placed.get("ok", false)):
		_failures.append("bed: placement refused at every candidate (%s)" % str(placed.get("reason", "")))
		return
	var cursor := _runner.trace_log_line_count()
	var result: Dictionary = runtime.camping_runtime.rest("bed")
	if not bool(result.get("ok", false)):
		_failures.append("bed: rest refused (%s)" % str(result))
		return
	for i in range(session.party.size()):
		var mon: Dictionary = session.get_party_member(i)
		if int(mon.get("current_hp", 0)) != int(mon.get("max_hp", 1)):
			_failures.append("bed: member %d left at %d/%d HP" % [i, int(mon.get("current_hp", 0)), int(mon.get("max_hp", 1))])
		if str(mon.get("status", "")) != "" or int(mon.get("sleep_turns", 0)) != 0:
			_failures.append("bed: member %d kept status '%s'" % [i, str(mon.get("status", ""))])
	if int(result.get("minutes_advanced", -1)) != DAY_REST_MINUTES:
		_failures.append("bed: day rest advanced %d minutes, not %d" % [int(result.get("minutes_advanced", -1)), DAY_REST_MINUTES])
	if not _runner.trace_log_has_since("rested", cursor, {"kind": "bed"}):
		_failures.append("bed: no rested{kind:bed} trace")
	if not _runner.trace_log_has_since("campsite_established", cursor, {"tile": [_rest_tile.x, _rest_tile.y], "kind": "bed"}):
		_failures.append("bed: no campsite_established trace")


# (c) Blackout: a forced defeat sends the player to the ESTABLISHED campsite —
# explicitly not the world origin, since the campsite tile is non-zero.
func _check_blackout() -> void:
	if not _failures.is_empty():
		return
	var runtime = _runtime()
	_runner.swap_party(runtime, ["BULBASAUR"])
	var brute: Dictionary = runtime.pokemon_rules.create_pokemon_instance(
		runtime.catalog.get_species(str(runtime.catalog.species.keys()[0])), 50, Callable(runtime.catalog, "get_move"))
	brute["max_hp"] = 9999
	brute["current_hp"] = 9999
	var cursor := _runner.trace_log_line_count()
	runtime.start_wild_battle(brute)
	runtime.battle_runtime._player_mon["current_hp"] = 0
	var result: Dictionary = runtime.perform_battle_move(_safe_move_index(runtime.battle_runtime._player_mon))
	if str(result.get("outcome", "")) != "defeat":
		_failures.append("blackout: defeat path reached outcome '%s'" % str(result.get("outcome", "")))
	elif runtime.session.player_tile != runtime.session.campsite_tile or runtime.session.player_tile != _rest_tile:
		_failures.append("blackout: player returned to %s, not the campsite %s" % [str(runtime.session.player_tile), str(_rest_tile)])
	elif _rest_tile == Vector2i.ZERO:
		_failures.append("blackout: the campsite is the world origin; the non-origin proof is vacuous")
	elif not _runner.trace_log_has_since("battle_finished", cursor, {"outcome": "defeat"}):
		_failures.append("blackout: no battle_finished{outcome:defeat} trace")
	_runner.resync_player_tile(_world(), _player(), runtime)


# (d) Save round-trip: the campsite anchor and the exact bag persist (a
# pre-Phase-2 save may lack sleeping_bag, so preservation — not presence — is the
# honest assert; a fresh game's STARTING_BAG always carries it).
func _check_save_roundtrip() -> bool:
	if not _failures.is_empty():
		return false
	var session = _runtime().session
	var bag_before: Dictionary = session.bag.duplicate(true)
	_runner.save_and_reload(_world(), _runtime())
	var ok: bool = session.campsite_tile == _rest_tile and session.bag == bag_before
	if not ok:
		_failures.append("save: campsite %s / bag %s did not survive the round-trip" % [str(session.campsite_tile), str(session.bag)])
	return ok


# Member 0: 1 HP + PSN (the bag must leave the status); member 1: fainted (revive).
func _damage_party() -> void:
	var session = _runtime().session
	var hurt: Dictionary = session.get_party_member(0)
	hurt["current_hp"] = 1
	hurt["status"] = "PSN"
	session.set_party_member(0, hurt)
	var fainted: Dictionary = session.get_party_member(1)
	fainted["current_hp"] = 0
	session.set_party_member(1, fainted)


# A damaging move that cannot heal the 0-HP player mon back (heal/leech would stall the defeat path).
func _safe_move_index(mon: Dictionary) -> int:
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		var effect := str((moves[i] as Dictionary).get("effect", ""))
		if int(moves[i].get("power", 0)) > 0 and int(moves[i].get("pp", 0)) > 0 and effect != "EFFECT_LEECH_HIT" and effect != "EFFECT_HEAL":
			return i
	return 0


# Non-zero open rest tile (so the blackout non-origin proof is real) with >= 2
# open neighbors (one becomes the bed, one stays an exit); ring order keeps the
# pick deterministic under the seed.
func _find_rest_site(center: Vector2i) -> Dictionary:
	for ring in range(1, 9):
		for tile in _runner.ring_around(center, ring):
			if tile == Vector2i.ZERO or not _open(tile):
				continue
			var beds: Array = []
			for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
				if _open(tile + direction):
					beds.append(tile + direction)
			if beds.size() >= 2:
				return {"rest": tile, "beds": beds}
	return {}


func _open(tile: Vector2i) -> bool:
	var logic: Dictionary = _world().get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
		and str(logic.get("structure_id", "")).is_empty()


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
