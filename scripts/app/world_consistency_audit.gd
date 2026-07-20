extends Node

# Lane 1 of the autonomous oracle suite (spec: docs/superpowers/specs/
# 2026-07-18-autonomous-playtesting-oracles-design.md). Tiles around spawn are
# bucketed per biome and category (prop, gate, tall_grass, blocked, walkable)
# so rare classes cannot slip past a flat cap; for every sample the generator
# logic, the rendered scene textures, and the collision/movement answers must
# agree. Spatial halves (z-order, player rect) live in world_spatial_audit.gd.
# Expectations anchor to source art and the model's own solid-prop knowledge,
# never to the code under test. The override extension stamps one real cut,
# then cross-checks every overridden tile across logic/render/collision.
# Encounters are muted. Save guard: the dispatcher.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const TileTextureCache := preload("res://scripts/runtime/tile_texture_cache.gd")
const WorldSpatialAudit := preload("res://scripts/app/world_spatial_audit.gd")

const SAMPLE_RADIUS := 20
const SAMPLES_PER_CATEGORY := 4
const MAX_FAILURES := 20
# Biomes carrying the tall-grass encounter mechanic (biome_defs.gd); the
# others encounter biome-wide by design and render no overlay.
const TALL_GRASS_BIOMES := ["GRASSLAND", "FOREST", "SAVANNA"]
# Model truth independent of the data under test: these props are solid
# structures, so a walkable tile rendering one is a world-data regression.
const SOLID_PROP_PATHS := [
	"res://pokewilds/tiles/tree1.png",
	"res://pokewilds/tiles/swamp/tree13.png",
	"res://pokewilds/tiles/spooky/tree1.png",
	"res://pokewilds/tiles/cactus1.png",
	"res://pokewilds/rock_small1.png",
	"res://pokewilds/tiles/lava_sheet1.png",
]

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


# Mutation-lane extension: stamps one real override through the resolver (a
# cut-capable party on a tree), then cross-checks every tile in
# overrides_for_save() across logic (mutated, walkable, no prop, no block
# reason), render (no prop sprite, matching ground), and collision (step in).
func _audit_overridden_tiles(center: Vector2i) -> void:
	var party_before: Array = _runner.swap_party(_runtime(), ["BULBASAUR"])
	var found := _runner.find_harvest_target(_world(), center, SAMPLE_RADIUS, "cut")
	if found.is_empty():
		_failures.append({"kind": "override_target_missing", "note": "no cut target within %d tiles" % SAMPLE_RADIUS})
	elif not bool(_runtime().harvest_tile(found["tile"]).get("ok", false)):
		_failures.append({"tile": [found["tile"].x, found["tile"].y], "kind": "override_harvest_refused"})
	elif not _runtime().world_overrides_for_save().has("%d,%d" % [found["tile"].x, found["tile"].y]):
		_failures.append({"tile": [found["tile"].x, found["tile"].y], "kind": "override_not_saved"})
	_runner.restore_party(_runtime(), party_before)
	var overridden: Array = []
	for key in _runtime().world_overrides_for_save().keys():
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
		if not _textures_match(_world().get_tile_base_texture(tile), _tex_cache.base_texture(_world().get_tile_render_data(tile))):
			_failures.append({"tile": [tile.x, tile.y], "kind": "override_base_mismatch"})
		await _check_movement_probe(tile)


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
	if not _textures_match(_world().get_tile_base_texture(tile), _tex_cache.base_texture(render)):
		_failures.append({"tile": [tile.x, tile.y], "kind": "base_texture_mismatch"})
	var prop_path := str(logic.get("prop_path", ""))
	var shown_prop: Texture2D = _world().get_tile_prop_texture(tile)
	if prop_path.is_empty() and shown_prop != null:
		_failures.append({"tile": [tile.x, tile.y], "kind": "phantom_prop"})
	elif not prop_path.is_empty():
		if shown_prop == null:
			_failures.append({"tile": [tile.x, tile.y], "kind": "missing_prop"})
		elif not _textures_match(shown_prop, _tex_cache.prop_texture(render)):
			_failures.append({"tile": [tile.x, tile.y], "kind": "prop_texture_mismatch"})
	var walkable: bool = _world().is_tile_walkable(tile)
	if walkable != bool(logic.get("walkable", true)):
		_failures.append({"tile": [tile.x, tile.y], "kind": "walkable_mismatch", "logic": logic.get("walkable"), "view": walkable})
	if not walkable and _world().get_traversal_block_reason(tile).is_empty():
		_failures.append({"tile": [tile.x, tile.y], "kind": "block_without_reason"})
	if walkable and prop_path in SOLID_PROP_PATHS:
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
	var has_overlay := not _textures_match(_world().get_tile_base_texture(tile), _tex_cache.base_texture(plain))
	if bool(render.get("encounter", false)) != has_overlay:
		_failures.append({"tile": [tile.x, tile.y], "kind": "tall_grass_mismatch", "encounter": render.get("encounter"), "overlay": has_overlay})


func _check_movement_probe(tile: Vector2i) -> void:
	var spot := _runner.stand_spot(_world(), tile)
	if spot.is_empty():
		return
	_movement_checked += 1
	_runner.teleport_player(_world(), _player(), _runtime(), spot["from_tile"])
	await _settle_movement()
	var expected := _expected_walkable(tile)
	var accepted: bool = _player().smoke_step(spot["direction"])
	var moved := false
	if accepted:
		await _player().tile_changed
		moved = _player().tile_position == tile
	if moved != expected or accepted != expected:
		_failures.append({"tile": [tile.x, tile.y], "kind": "movement_mismatch", "expected_walkable": expected, "moved": moved, "accepted": accepted})
	_spatial_checked += 1
	_failures.append_array(_spatial.check_player_rect(_world(), _player()))


# The model's expectation: solid props block no matter what the data says.
func _expected_walkable(tile: Vector2i) -> bool:
	if str(_world().get_tile_logic(tile).get("prop_path", "")) in SOLID_PROP_PATHS:
		return false
	return _world().is_tile_walkable(tile)


func _textures_match(a: Texture2D, b: Texture2D) -> bool:
	if a == null or b == null:
		return a == b
	var image_a := a.get_image()
	var image_b := b.get_image()
	if image_a.get_size() != image_b.get_size():
		return false
	return image_a.get_data() == image_b.get_data()


# A failed probe can leave the player mid-walk; never step again until it ends.
func _settle_movement() -> void:
	if _player()._moving:
		await _player().tile_changed


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
