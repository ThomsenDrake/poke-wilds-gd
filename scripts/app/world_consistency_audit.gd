extends Node

# Lane 1 of the autonomous oracle suite (spec: docs/superpowers/specs/
# 2026-07-18-autonomous-playtesting-oracles-design.md). Tiles around spawn are
# bucketed per biome and category so rare classes cannot slip past a flat cap;
# for every sample the generator logic, the rendered scene textures, and the
# collision/movement answers must agree. The spatial + movement halves and the
# shared solid-prop/texture helpers live in world_spatial_audit.gd. Expectations
# anchor to source art, never to the code under test. Two mutation lanes stamp
# one real override each — a cut (clears) and a wall+door (build) — then
# cross-check every mutated tile across logic/render/collision. Save guard: dispatcher.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const TileTextureCache := preload("res://scripts/runtime/tile_texture_cache.gd")
const WorldSpatialAudit := preload("res://scripts/app/world_spatial_audit.gd")

const SAMPLE_RADIUS := 20
const SAMPLES_PER_CATEGORY := 4
const MAX_FAILURES := 20
# Biomes carrying the tall-grass encounter mechanic (biome_defs.gd); the
# others encounter biome-wide by design and render no overlay.
const TALL_GRASS_BIOMES := ["GRASSLAND", "FOREST", "SAVANNA"]

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _tex_cache = TileTextureCache.new()
var _spatial = WorldSpatialAudit.new()
var _failures: Array = []
var _tiles_checked := 0
var _movement_checked := 0
var _spatial_checked := 0

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var center: Vector2i = _player().tile_position
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0
	await _audit_tiles(center)
	await _audit_overridden_tiles(center)
	await _audit_placed_structures(center)
	var z_result: Dictionary = _spatial.audit_z_order(_world(), _player(), _runtime(), center, _runner)
	_failures.append_array(z_result["failures"])
	_spatial_checked += int(z_result["checked"])
	_player().encounter_chance = saved_chance
	if _failures.is_empty():
		_runtime().emit_trace("world_consistency_audit_passed", "SmokeScenarios", {
			"tiles_checked": _tiles_checked,
			"movement_checked": _movement_checked,
			"spatial_checked": _spatial_checked,
			"failures": 0
		})
	else:
		for failure in _failures:
			push_error(str(failure))


func _audit_tiles(center: Vector2i) -> void:
	var buckets := {}
	for dy in range(-SAMPLE_RADIUS, SAMPLE_RADIUS + 1):
		for dx in range(-SAMPLE_RADIUS, SAMPLE_RADIUS + 1):
			var tile := center + Vector2i(dx, dy)
			var logic: Dictionary = _world().get_tile_logic(tile)
			var key := str(logic.get("biome", "")) + "|" + _tile_category(logic)
			if not buckets.has(key):
				buckets[key] = []
			(buckets[key] as Array).append(tile)
	for key in buckets.keys():
		for tile in _runner.even_samples(buckets[key], SAMPLES_PER_CATEGORY):
			_check_tile(tile)
			_check_tall_grass(tile)
			await _check_movement_probe(tile)
			if _failures.size() > MAX_FAILURES:
				return


# Clears lane: stamps one real override through the resolver (a cut-capable
# party on a tree), then cross-checks every tile in the generator's clears-only
# overrides_for_save() across logic (mutated, walkable, no prop, no block
# reason), render (no prop sprite, matching ground), and collision (step in).
# Iterating the clears-only map keeps the build placements from contaminating it.
func _audit_overridden_tiles(center: Vector2i) -> void:
	var party_before: Array = _runner.swap_party(_runtime(), ["BULBASAUR"])
	var found := _runner.find_harvest_target(_world(), center, SAMPLE_RADIUS, "cut")
	if found.is_empty():
		_failures.append({"kind": "override_target_missing", "note": "no cut target within %d tiles" % SAMPLE_RADIUS})
	elif not bool(_runtime().harvest_tile(found["tile"]).get("ok", false)):
		_failures.append({"tile": [found["tile"].x, found["tile"].y], "kind": "override_harvest_refused"})
	elif not _runtime()._world_gen.overrides_for_save().has("%d,%d" % [found["tile"].x, found["tile"].y]):
		_failures.append({"tile": [found["tile"].x, found["tile"].y], "kind": "override_not_saved"})
	_runner.restore_party(_runtime(), party_before)
	var overridden: Array = []
	for key in _runtime()._world_gen.overrides_for_save().keys():
		var parts := str(key).split(",")
		if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
			overridden.append(Vector2i(parts[0].to_int(), parts[1].to_int()))
	for tile in overridden:
		_tiles_checked += 1
		var logic: Dictionary = _world().get_tile_logic(tile)
		if not bool(logic.get("mutated", false)) or not bool(logic.get("walkable", false)) or not str(logic.get("prop_path", "")).is_empty():
			_failures.append({"tile": [tile.x, tile.y], "kind": "override_logic_disagree"})
		elif not str(logic.get("block_reason", "")).is_empty() or not _world().get_traversal_block_reason(tile).is_empty():
			_failures.append({"tile": [tile.x, tile.y], "kind": "override_block_reason"})
	for tile in _runner.even_samples(overridden, SAMPLES_PER_CATEGORY):
		_world().sync_visible(tile)
		if _world().get_tile_prop_texture(tile) != null:
			_failures.append({"tile": [tile.x, tile.y], "kind": "override_prop_rendered"})
		if not WorldSpatialAudit.textures_match(_world().get_tile_base_texture(tile), _tex_cache.base_texture(_world().get_tile_render_data(tile))):
			_failures.append({"tile": [tile.x, tile.y], "kind": "override_base_mismatch"})
		await _check_movement_probe(tile)


# Build lane: places a wall + a door (a Build-capable Machop party on granted
# materials) then reuses the generic logic/render check (_check_tile) and the
# collision probe on each — a placed structure must agree across all three
# sources like any base tile: the wall reads solid (non-walkable + block reason
# + rejected step), the door a walkable opening (accepted step).
func _audit_placed_structures(center: Vector2i) -> void:
	var party_before: Array = _runner.swap_party(_runtime(), ["MACHOP"])
	for item_id in ["log", "dry_soil", "hard_stone"]:
		_runtime().session.add_item(item_id, 6)
	var pair := _find_build_pair(center)
	if pair.is_empty():
		_failures.append({"kind": "placed_target_missing", "note": "no adjacent placeable pair within %d tiles" % SAMPLE_RADIUS})
	else:
		# A refused placement must fail the lane, not pass vacuously on the bare tile.
		for structure_id in ["wall", "door"]:
			if not bool(_runtime().build_runtime.try_place(pair[structure_id], structure_id, {}).get("ok", false)):
				_failures.append({"tile": [pair[structure_id].x, pair[structure_id].y], "kind": "placed_refused", "structure_id": structure_id})
			_check_tile(pair[structure_id])
			await _check_movement_probe(pair[structure_id])
	_runner.restore_party(_runtime(), party_before)


# Adjacent open-ground pair near center, each with a stand neighbor other than its partner so the probe can stand once both are built.
func _find_build_pair(center: Vector2i) -> Dictionary:
	for radius in range(1, SAMPLE_RADIUS + 1):
		for tile in _runner.ring_around(center, radius):
			var other: Vector2i = tile + Vector2i.RIGHT
			if _placeable(tile) and _placeable(other) and _has_stand(tile, other) and _has_stand(other, tile):
				return {"wall": tile, "door": other}
	return {}


func _placeable(tile: Vector2i) -> bool:
	var logic: Dictionary = _world().get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() and str(logic.get("structure_id", "")).is_empty()


func _has_stand(tile: Vector2i, exclude: Vector2i) -> bool:
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if tile + direction != exclude and _world().is_tile_walkable(tile + direction):
			return true
	return false


func _tile_category(logic: Dictionary) -> String:
	if not str(logic.get("prop_path", "")).is_empty():
		return "prop"
	if not str(logic.get("requires_field_move", "")).is_empty():
		return "gate"
	if not str(logic.get("tall_grass_path", "")).is_empty():
		return "tall_grass"
	return "blocked" if not bool(logic.get("walkable", true)) else "walkable"


func _check_tile(tile: Vector2i) -> void:
	_tiles_checked += 1
	var logic: Dictionary = _world().get_tile_logic(tile)
	if logic.is_empty():
		_failures.append({"tile": [tile.x, tile.y], "kind": "empty_logic"})
		return
	_world().sync_visible(tile)
	var render: Dictionary = _world().get_tile_render_data(tile)
	if not WorldSpatialAudit.textures_match(_world().get_tile_base_texture(tile), _tex_cache.base_texture(render)):
		_failures.append({"tile": [tile.x, tile.y], "kind": "base_texture_mismatch"})
	var prop_path := str(logic.get("prop_path", ""))
	var shown_prop: Texture2D = _world().get_tile_prop_texture(tile)
	if prop_path.is_empty() and shown_prop != null:
		_failures.append({"tile": [tile.x, tile.y], "kind": "phantom_prop"})
	elif not prop_path.is_empty():
		if shown_prop == null:
			_failures.append({"tile": [tile.x, tile.y], "kind": "missing_prop"})
		elif not WorldSpatialAudit.textures_match(shown_prop, _tex_cache.prop_texture(render)):
			_failures.append({"tile": [tile.x, tile.y], "kind": "prop_texture_mismatch"})
	var walkable: bool = _world().is_tile_walkable(tile)
	if walkable != bool(logic.get("walkable", true)):
		_failures.append({"tile": [tile.x, tile.y], "kind": "walkable_mismatch", "logic": logic.get("walkable"), "view": walkable})
	if not walkable and _world().get_traversal_block_reason(tile).is_empty():
		_failures.append({"tile": [tile.x, tile.y], "kind": "block_without_reason"})
	if walkable and prop_path in WorldSpatialAudit.SOLID_PROP_PATHS:
		_failures.append({"tile": [tile.x, tile.y], "kind": "solid_prop_walkable", "prop": prop_path})


# Encounter tiles in tall-grass biomes must render the overlay (their base
# texture must differ from the same tile without it); other tiles must not.
func _check_tall_grass(tile: Vector2i) -> void:
	var render: Dictionary = _world().get_tile_render_data(tile)
	if not str(render.get("biome", "")) in TALL_GRASS_BIOMES:
		return
	var plain := render.duplicate()
	plain["tall_grass_path"] = ""
	plain["tall_grass_key_color"] = ""
	var has_overlay := not WorldSpatialAudit.textures_match(_world().get_tile_base_texture(tile), _tex_cache.base_texture(plain))
	if bool(render.get("encounter", false)) != has_overlay:
		_failures.append({"tile": [tile.x, tile.y], "kind": "tall_grass_mismatch", "encounter": render.get("encounter"), "overlay": has_overlay})


# Collision agreement, delegated to the shared spatial/movement probe; folds the
# probe's movement + spatial counters and failures back into the audit totals.
func _check_movement_probe(tile: Vector2i) -> void:
	var result: Dictionary = await _spatial.movement_probe(_world(), _player(), _runtime(), _runner, tile)
	_movement_checked += int(result["movement"])
	_spatial_checked += int(result["spatial"])
	_failures.append_array(result["failures"])


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
