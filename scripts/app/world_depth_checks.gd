extends Node

# World-depth split checks (Phase 7; world-depth.md § Smoke validation): landmark_flow's pool/ruins/tower/save
# cases live here for the app budget. Every scope assert reads the LIVE token tables; miss-002 named reds.

const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd")
const BuildRuntime := preload("res://scripts/runtime/build_runtime.gd")
# Domain access rides the runtimes' own preloads (the app layer may not preload
# domain directly — check_architecture.gd's layer table).
const Landmarks := LandmarkRuntime.Landmarks
const Structures := BuildRuntime.Structures

const ORIGIN := Vector2i.ZERO
const TOWER_TRACK := "res://pokewilds/music/Wilds_HeartTower.ogg" # landmark_runtime.TOWER_TRACK (private const): the asset the entry switch arms
const RUINS_GUARD_LOCAL := Vector2i(10, 5) # landmark_runtime.UNDERGROUND_GUARD_LOCAL (private const)

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []
var _mansion_origin := Vector2i.ZERO


func setup(ctx: Dictionary, runner, failures: Array, mansion_origin: Vector2i) -> void:
	_ctx = ctx; _runner = runner; _failures = failures; _mansion_origin = mansion_origin


# The mansion-exclusive proof: PKMNMANSION grounds the pool (DITTO spawns nowhere else —
# breed_flow cross-relies on Ditto-as-universal-parent), live draws stay INSIDE it, and a
# tile ONE STEP past the footprint reverts to the world-biome pool (scope is footprint-local).
func run_mansion_pool_case(runtime) -> bool:
	var start: int = _failures.size()
	var inside := _first_token_tile(runtime, Landmarks.MANSION_ID, Landmarks.TOKEN_MANSION)
	if inside.is_empty():
		_failures.append("mansion_pool: no encounter tile carries PKMNMANSION under the resolver")
		return false
	var biome := str(inside["logic"].get("biome", ""))
	var pool: Dictionary = _pool(runtime, biome, Landmarks.TOKEN_MANSION)
	for species_id in ["DITTO", "GROWLITHE", "KOFFING", "MAGMAR"]:
		_ensure(pool["ids"].has(species_id), "mansion_pool: %s absent from the PKMNMANSION pool" % species_id)
	_ensure(not bool(pool.get("used_fallback", false)), "mansion_pool: the token filter fell back to the full catalog (%s)" % str(pool.get("reason", "")))
	for draw in range(3): # shared-stream draws INSIDE the footprint stay inside the scoped pool (mutation-proven scope)
		var mon: Dictionary = runtime.generate_wild_encounter(inside["tile"], biome)
		_ensure(not mon.is_empty() and pool["ids"].has(str(mon.get("species_id", ""))), "mansion_pool: draw %d left the scoped pool (%s)" % [draw, str(mon.get("species_id", ""))])
	_ensure(not Structures.can_place_on(inside["logic"]), "mansion_pool: Structures.can_place_on accepted a landmark tile")
	var open_logic := {"walkable": true, "prop_path": "", "structure_id": "", "landmark_id": ""} # positive control: the refusal must be landmark-SCOPED, not a global placement shutdown
	_ensure(Structures.can_place_on(open_logic), "mansion_pool: can_place_on refuses open non-landmark ground (over-refusal)")
	var stamped_logic := open_logic.duplicate(); stamped_logic["landmark_id"] = Landmarks.MANSION_ID
	_ensure(not Structures.can_place_on(stamped_logic), "mansion_pool: the landmark_id clause alone no longer flips can_place_on")
	# One step past the footprint edge: no stamp, and the empty token is a no-op.
	var outside := _outside_tile(runtime)
	if outside.is_empty():
		_failures.append("mansion_pool: no clean tile one step past the footprint edge")
		return false
	var outside_biome := str(outside["logic"].get("biome", ""))
	_ensure(str(outside["logic"].get("encounter_token", "")) == "" and str(outside["logic"].get("landmark_id", "")) == "", "mansion_pool: the outside tile still carries a landmark stamp")
	var pool_tokened: Dictionary = _pool(runtime, outside_biome, "")
	var pool_plain: Dictionary = _pool_plain(runtime, outside_biome) # the pre-Phase-7 call shape
	_ensure(_same_ids(pool_tokened, pool_plain), "mansion_pool: the empty landmark_token perturbed the world-biome pool")
	if not bool(pool_tokened.get("used_fallback", false)):
		_ensure(not pool_tokened["ids"].has("DITTO"), "mansion_pool: DITTO leaks into the world-biome pool (mansion-exclusivity broken)")
	return _failures.size() == start


# Ruins scope off the live token tables: RUINS_OUTER grounds (BELDUM/SOLROCK), RUINS_INNER
# = the Lunatone pool + the curated high-level statics (VOLCARONA 38-45 — the flagged-
# divergence witness pinning the SHIPPED curation, not the wiki); underground tiles carry
# encounter=FALSE and the DUSCLOPS guardian materializes aggressive under opt-in activation.
func run_ruins_case(runtime) -> bool:
	var start: int = _failures.size()
	var outer := _first_token_tile(runtime, Landmarks.RUINS_ID, Landmarks.TOKEN_RUINS_OUTER)
	if outer.is_empty():
		_failures.append("ruins: no encounter tile carries RUINS_OUTER")
		return false
	var outer_pool: Dictionary = _pool(runtime, str(outer["logic"].get("biome", "")), Landmarks.TOKEN_RUINS_OUTER)
	for species_id in ["BELDUM", "SOLROCK"]:
		_ensure(outer_pool["ids"].has(species_id), "ruins: %s absent from the RUINS_OUTER pool" % species_id)
	var inner := _first_token_tile(runtime, Landmarks.RUINS_ID, Landmarks.TOKEN_RUINS_INNER)
	if inner.is_empty():
		_failures.append("ruins: no encounter tile carries RUINS_INNER")
		return false
	var inner_pool: Dictionary = _pool(runtime, str(inner["logic"].get("biome", "")), Landmarks.TOKEN_RUINS_INNER)
	_ensure(inner_pool["ids"].has("LUNATONE"), "ruins: LUNATONE absent from the RUINS_INNER pool")
	var scope: Dictionary = runtime.landmark_runtime.encounter_scope_for(inner["tile"], str(inner["logic"].get("biome", "")))
	var curated: Dictionary = scope.get("curated", {}) if scope.get("curated", {}) is Dictionary else {}
	var extra: Array = scope.get("extra_ids", []) if scope.get("extra_ids", []) is Array else []
	_ensure(extra.has("VOLCARONA") and curated.get("VOLCARONA", []) == [38, 45], "ruins: the RUINS_INNER curated static lost VOLCARONA 38-45")
	# Underground: encounter=FALSE on the guardian floor; the guardian rides the Phase-6 stationary seam (opt-in activation).
	var guard_tile: Vector2i = _ruins_origin(runtime) + RUINS_GUARD_LOCAL
	var guard_logic: Dictionary = runtime._world_gen.get_tile_logic(guard_tile)
	_ensure(str(guard_logic.get("landmark_id", "")) == Landmarks.RUINS_ID and not bool(guard_logic.get("encounter", true)), "ruins: the underground guard tile still rolls wild encounters")
	_ensure(not Structures.can_place_on(outer["logic"]), "ruins: Structures.can_place_on accepted a landmark tile")
	var saved_active: bool = runtime.overworld_mons_runtime.active
	runtime.overworld_mons_runtime.active = true # opt in: the dispatcher holds it false for non-entity scenarios
	var guard_cursor: int = _runner.trace_log_line_count()
	_runner.teleport_player(_world(), _player(), runtime, guard_tile)
	runtime.note_player_step()
	_ensure(_runner.trace_log_has_since("landmark_entity_spawned", guard_cursor, {"species_id": Landmarks.RUINS_UNDERGROUND_SPECIES, "landmark_id": Landmarks.RUINS_ID}), "ruins: no landmark_entity_spawned{DUSCLOPS} under the guard band") # the AGGRESSIVE disposition witness rides landmark_guardian_checks (the trace literal is a constant==constant tautology; audit Major #1)
	runtime.overworld_mons_runtime.active = saved_active
	return _failures.size() == start


# Heart Tower: footprint + the entry witness + the dedicated field track + the EXIT host-biome restore (R10).
func run_tower_case(runtime) -> bool:
	var start: int = _failures.size()
	var stand := _first_walkable(runtime, Landmarks.TOWER_ID)
	if stand.is_empty():
		_failures.append("tower: landmarks_in_world derives no walkable heart_tower footprint tile")
		return false
	_ensure(not Structures.can_place_on(stand["logic"]), "tower: Structures.can_place_on accepted a landmark tile")
	var cursor: int = _runner.trace_log_line_count()
	_runner.teleport_player(_world(), _player(), runtime, stand["tile"])
	runtime.note_player_step()
	_ensure(_runner.trace_log_has_since("landmark_entered", cursor, {"landmark_id": Landmarks.TOWER_ID, "first_entry": true}), "tower: no landmark_entered{heart_tower,first_entry}")
	_ensure(_runner.trace_log_has_since("landmark_music", cursor, {"landmark_id": Landmarks.TOWER_ID, "track": TOWER_TRACK}), "tower: no landmark_music{heart_tower} switch trace on first entry")
	_ensure(ResourceLoader.exists(TOWER_TRACK), "tower: the dedicated field track is missing (%s)" % TOWER_TRACK)
	var footprint: Rect2i = (_landmark(runtime, Landmarks.TOWER_ID)["footprint"] as Rect2i) # R10: the field-music EXIT restore — step OUT, the host-biome theme restores (music_track_selected)
	var outside := Vector2i(stand["tile"].x, footprint.position.y - 1) # one row above the footprint: outside (landmark_id ""), the host biome
	var exit_cursor: int = _runner.trace_log_line_count()
	_runner.teleport_player(_world(), _player(), runtime, outside); runtime.note_player_step()
	_ensure(_runner.trace_log_has_since("music_track_selected", exit_cursor, {"kind": str(runtime._world_gen.get_tile_logic(outside).get("biome", ""))}), "tower: no music_track_selected host-biome restore on exit (the exit-restore seam is dead)")
	return _failures.size() == start


# Puzzle state round-trip THROUGH THE FROZEN SEAM (never the keying): the solved mansion
# survives save -> reload -> apply (v4-additive top-level key) + the basement door overlay.
func run_save_roundtrip_case(runtime) -> bool:
	var start: int = _failures.size()
	var before: Dictionary = _seam_mansion(runtime)
	_ensure(bool(before.get("unlocked", false)) and bool(before.get("key_taken", false)), "save: the puzzle is not solved before the round-trip")
	var payload: Dictionary = _runner.save_and_reload(_world(), runtime)
	_ensure(not payload.is_empty(), "save: the just-written payload failed to reload")
	var after: Dictionary = _seam_mansion(runtime)
	_ensure(after == before, "save: landmark_state drifted across the round-trip (seam read)")
	var sewer_door: Dictionary = runtime._world_gen.get_tile_logic(_mansion_origin + Vector2i(4, 5)) # SEWER_DOOR_LOCAL
	_ensure(bool(sewer_door.get("walkable", false)), "save: the basement door re-sealed after the reload")
	return _failures.size() == start


# --- helpers ------------------------------------------------------------------------
func _seam_mansion(runtime) -> Dictionary: # the FROZEN seam — the checks never key the save surface directly
	var all: Dictionary = runtime.session.landmark_state_for(ORIGIN)
	var raw: Variant = all.get(Landmarks.MANSION_ID, {})
	return Landmarks.mansion_state_from(raw if raw is Dictionary else {})


func _landmark(runtime, landmark_id: String) -> Dictionary:
	for landmark in Landmarks.landmarks_in_world(runtime.get_world_seed(), ORIGIN):
		if str(landmark["landmark_id"]) == landmark_id:
			return landmark
	return {}


func _ruins_origin(runtime) -> Vector2i:
	var ruins := _landmark(runtime, Landmarks.RUINS_ID)
	return (ruins["footprint"] as Rect2i).position if not ruins.is_empty() else Vector2i.ZERO


# First resolver-walkable ENCOUNTER tile in a footprint carrying the token ({} when none — a loud named failure upstream).
func _first_token_tile(runtime, landmark_id: String, token: String) -> Dictionary:
	for row in _footprint_tiles(runtime, landmark_id):
		var logic: Dictionary = runtime._world_gen.get_tile_logic(row)
		if bool(logic.get("walkable", false)) and bool(logic.get("encounter", false)) and str(logic.get("encounter_token", "")) == token:
			return {"tile": row, "logic": logic}
	return {}


func _first_walkable(runtime, landmark_id: String) -> Dictionary:
	for row in _footprint_tiles(runtime, landmark_id):
		var logic: Dictionary = runtime._world_gen.get_tile_logic(row)
		if bool(logic.get("walkable", false)):
			return {"tile": row, "logic": logic}
	return {}


# One step past the mansion's west edge, vertically centered — the SPECIFIC geometric tile:
# anchor disjoint INCLUDES borders, so one step past any edge is un-stamped BY CONSTRUCTION;
# a stamp there is a real anchor-seam regression, named loudly (the dx-walk selector this
# replaced guaranteed half its own assert and could never red on it).
func _outside_tile(runtime) -> Dictionary:
	var mid_y: int = _mansion_origin.y + int(Landmarks.MANSION_SIZE.y / 2)
	var first := Vector2i(_mansion_origin.x - 1, mid_y)
	var logic: Dictionary = runtime._world_gen.get_tile_logic(first)
	if str(logic.get("landmark_id", "")) != "":
		_ensure(false, "mansion_pool: the one-step-west tile %s still carries a landmark stamp" % str(first))
		return {}
	return {"tile": first, "logic": logic}


func _footprint_tiles(runtime, landmark_id: String) -> Array:
	var landmark := _landmark(runtime, landmark_id)
	if landmark.is_empty():
		return []
	var footprint: Rect2i = landmark["footprint"]
	var tiles: Array = []
	for y in range(footprint.position.y, footprint.end.y):
		for x in range(footprint.position.x, footprint.end.x):
			tiles.append(Vector2i(x, y))
	return tiles


func _pool(runtime, biome: String, token: String) -> Dictionary:
	return runtime._biome_encounters.filter_species_ids(runtime.catalog.species, biome, "DAY", token)


func _pool_plain(runtime, biome: String) -> Dictionary: # the pre-Phase-7 two-arg call shape (the landmark_token param defaults to "")
	return runtime._biome_encounters.filter_species_ids(runtime.catalog.species, biome, "DAY")


func _same_ids(a: Dictionary, b: Dictionary) -> bool:
	return a.get("ids", []) == b.get("ids", [])


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
