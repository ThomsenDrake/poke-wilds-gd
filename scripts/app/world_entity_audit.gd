extends Node
# Lane 1b of the autonomous oracle suite: the world_consistency_audit clears lane
# extracted at its 220 wall + the Phase 6 ENTITY lane (spec: docs/product-specs/
# overworld-pokemon.md § Smoke validation; exit criterion — both audits reach mon
# entities): spawn determinism (same (seed, steps, player tile) re-derives the identical
# set); per-biome coverage + disposition correctness (ALL 11 biomes iterated, each must
# show >=1 live roamer; named wiki examples checked off the live catalog where seen);
# tile validity + despawn hygiene; logic/render agreement vs the entity_layer sprites;
# a guardian probe. The subsystem SELF-ACTIVATES for the lane (the dispatcher leaves the
# audit inert for baseline protection) and stays synced at center for audit_z_order's entity scan; restore_inactive() closes the gate.
const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const TileTextureCache := preload("res://scripts/runtime/tile_texture_cache.gd")
const WorldSpatialAudit := preload("res://scripts/app/world_spatial_audit.gd")
const OverworldMonsProbe := preload("res://scripts/runtime/overworld_mons_probe.gd")
const SAMPLE_RADIUS := 20
const SAMPLES_PER_CATEGORY := 4
const CELL_SIZE := 8 # mirrors OverworldMons.CELL_SIZE (scenario contract)
const DESPAWN_CELLS := 3 # mirrors OverworldMons.DESPAWN_CELLS (spawn band == despawn band)
const MAX_ENTITY_SAMPLES := 8
const ALL_BIOMES := ["WATER", "SAND", "PLAINS", "GRASSLAND", "FOREST", "SAVANNA", "DESERT", "SWAMP", "ROCK", "SNOW", "LAVA"]
const DISPOSITIONS := ["TIMID", "FRIENDLY", "IRRITABLE", "AGGRESSIVE"]
const NOT_FOUND_PATH := "res://assets/source/pokemon/overworld_not_found.png" # tier-2 model truth
const EGG_SHEET_PATH := "res://assets/source/phione-egg.png"
const NEST_CENTERS := [Vector2i(88, 88), Vector2i(120, 88), Vector2i(88, 120), Vector2i(152, 88),
	Vector2i(88, 152), Vector2i(120, 120), Vector2i(184, 88), Vector2i(88, 184),
	Vector2i(152, 120), Vector2i(120, 152), Vector2i(216, 88), Vector2i(88, 216)]

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _tex_cache = TileTextureCache.new()
var _spatial = WorldSpatialAudit.new()
var probe = OverworldMonsProbe.new()
var _failures: Array = []
var _bridge_disconnected := false
var tiles_checked := 0
var movement_checked := 0
var spatial_checked := 0
func setup(ctx: Dictionary, runner: SmokeScenarioRunner, failures: Array) -> void:
	_ctx = ctx; _runner = runner; _failures = failures
# Clears lane (extracted verbatim from world_consistency_audit._audit_overridden_tiles): stamps one real override through the
# resolver, cross-checks every cleared tile across logic/render/collision (clears-only iteration keeps build placements out).
func run_overrides(center: Vector2i) -> void:
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
		tiles_checked += 1
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

# Entity lane; leaves the subsystem ACTIVE + synced at center for the z-order entity scan.
# The forced-battle bridge is disconnected for the lane (re-connected by restore_inactive):
# a guardian chase-catch during the probes must not auto-start main's battle presentation.
func run_entity_lane(center: Vector2i) -> void:
	var mons := _mons()
	if mons == null or not (mons as Object).has_method("live_entities_in"):
		_failures.append({"kind": "entity_runtime_missing"}); return
	mons.set("active", true)
	_disconnect_bridge()
	var runtime := _runtime()
	# (1) Spawn determinism: the same (seed, steps, player tile) re-derives the identical set.
	var saved_steps := int(runtime.session.total_steps)
	var saved_minutes := int(runtime.session.time_of_day_minutes)
	_reset(mons); _runner.teleport_player(_world(), _player(), runtime, center); runtime.note_player_step()
	var hash_a := probe.entity_hash(mons, center, 32)
	runtime.session.total_steps = saved_steps; runtime.session.time_of_day_minutes = saved_minutes
	_reset(mons); _runner.teleport_player(_world(), _player(), runtime, center); runtime.note_player_step()
	var hash_b := probe.entity_hash(mons, center, 32)
	if hash_a != hash_b or hash_a.is_empty():
		_failures.append({"kind": "entity_determinism", "empty": hash_a.is_empty()})
	# (2) Per-biome coverage + disposition correctness (every biome shows roaming mons).
	var anchors := probe.biome_anchors(_world(), ALL_BIOMES)
	var named := {} # species_id -> [spawn-cell biome, disposition] (roamers cross biomes; the stamp is spawn-pinned)
	for biome in ALL_BIOMES:
		var anchor: Vector2i = anchors.get(biome, Vector2i.MAX)
		if anchor == Vector2i.MAX:
			_failures.append({"kind": "entity_biome_missing", "biome": biome}); continue
		var roamers := 0
		var band_ring := absi(anchor.x) + absi(anchor.y)
		for k in range(8): # band-spread anchors: 2 rings x spread directions (a single anchor flakes at 25% presence)
			if k == 0: await get_tree().process_frame # flush the prior biome's deferred tile frees
			var stand: Vector2i = probe.stand_tile(_world(), probe.band_point(band_ring + 4 + (k % 2) * 8, k), biome)
			if stand == Vector2i.MAX: continue
			_runner.teleport_player(_world(), _player(), runtime, stand)
			runtime.note_player_step()
			for e in probe.live(mons, stand, 24):
				if str(e.get("kind", "")) != "mon": continue
				roamers += 1
				if not str(e.get("disposition", "")) in DISPOSITIONS:
					_failures.append({"kind": "entity_disposition_invalid", "species_id": str(e.species_id), "disposition": str(e.get("disposition", ""))})
				var cell_center: Vector2i = Vector2i(e.cell.x * CELL_SIZE + 4, e.cell.y * CELL_SIZE + 4)
				named[str(e.species_id)] = [str(_world().get_tile_logic(cell_center).get("biome", "")), str(e.get("disposition", ""))]
		if roamers == 0:
			_failures.append({"kind": "entity_biome_empty", "biome": biome})
	_ensure_named(named, "PIDGEY", "TIMID", "")
	_ensure_named(named, "JUMPLUFF", "FRIENDLY", "")
	_ensure_named(named, "TAUROS", "IRRITABLE", "")
	_ensure_named(named, "PRIMEAPE", "AGGRESSIVE", "SAVANNA")
	# (3) Tile validity + despawn hygiene; re-sync at center first ((2) strands the player on a biome band) — an empty sample fails LOUD, never vacuous.
	_runner.teleport_player(_world(), _player(), runtime, center); runtime.note_player_step()
	var player_cell := Vector2i(floori(float(center.x) / float(CELL_SIZE)), floori(float(center.y) / float(CELL_SIZE))); var sampled := 0
	for e in probe.live(mons, center, 24):
		if sampled >= MAX_ENTITY_SAMPLES: break
		sampled += 1; spatial_checked += 1
		var tile: Vector2i = e.tile; var logic: Dictionary = _world().get_tile_logic(tile)
		# Overlap = sharing an OBSTACLE: a BLOCKING prop (trees/rocks carry a block_reason) or a placement — ground decorations (bushes: walkable, no block_reason) and landmark floor stamps (world-depth.md § Landmarks (a): the guardian stands ON the ruins floor by design) are walkable ground, not obstacles; landmark walls red via the walkable rule below.
		var prop_blocks := not str(logic.get("prop_path", "")).is_empty() and not str(logic.get("block_reason", "")).is_empty()
		if str(logic.get("landmark_id", "")) == "" and (prop_blocks or not str(logic.get("structure_id", "")).is_empty()):
			_failures.append({"tile": [tile.x, tile.y], "kind": "entity_prop_overlap", "entity_id": str(e.get("id", ""))})
		if not bool(logic.get("walkable", false)) and str(logic.get("biome", "")) != "WATER":
			_failures.append({"tile": [tile.x, tile.y], "kind": "entity_unwalkable_tile"})
	if sampled == 0: _failures.append({"kind": "entity_tilevalidity_vacuous"})
	_failures.append_array(probe.tile_overlap_failures(mons, center, 24))
	# (4) Guardian probe: nest ring + Alpha badge + movement agreement on the guardian tile.
	var nest := probe.find_nest(mons, NEST_CENTERS, 56)
	if nest != Vector2i.ZERO:
		_runner.teleport_player(_world(), _player(), runtime, nest + Vector2i(2, 2))
		runtime.note_player_step(); runtime.note_player_step()
		var guardian := {}
		for e in probe.live(mons, nest, 12):
			if str(e.get("kind", "")) == "guardian":
				guardian = e; break
		if (guardian as Dictionary).is_empty():
			_failures.append({"kind": "entity_guardian_missing", "nest": [nest.x, nest.y]})
		else:
			await _check_movement_probe((guardian as Dictionary).tile)
	else: # LOUD, never silent (miss-002): nest presence is seed-conditioned, so a no-nest scan
		runtime.warn("WorldEntityAudit", "Guardian sublane skipped: no nest within the scan band.", {"centers": NEST_CENTERS.size()})
	# (5) Logic/render agreement via the entity_layer sprites (feet-origin convention).
	_runner.teleport_player(_world(), _player(), runtime, center)
	runtime.note_player_step()
	for _frame in range(4):
		await get_tree().process_frame
	var layer := _entity_layer()
	var rendered := 0
	if layer != null:
		for e in probe.live(mons, center, 20):
			if rendered >= MAX_ENTITY_SAMPLES: break
			var sprite: Sprite2D = layer.call("get_entity_sprite", e.tile)
			if sprite == null: continue
			rendered += 1; spatial_checked += 1
			var feet: Vector2 = layer.call("map_to_world", e.tile) + Vector2(0, 16)
			if sprite.position.distance_to(feet) > 1.0:
				_failures.append({"tile": [e.tile.x, e.tile.y], "kind": "entity_feet_origin", "entity_id": str(e.get("id", ""))})
			var want := EGG_SHEET_PATH if str(e.get("kind", "")) == "egg" else _species_sheet_path(str(e.species_id))
			var path := _atlas_path(sprite)
			if not path.is_empty() and want != path:
				_failures.append({"tile": [e.tile.x, e.tile.y], "kind": "entity_texture_mismatch", "path": path, "want": want})
	if rendered == 0:
		_failures.append({"kind": "entity_render_absent", "note": "no entity sprite materialized near center"})
func restore_inactive() -> void:
	var mons := _mons()
	if mons == null: return
	mons.call("take_pending_encounter") # never leave an armed seam behind
	mons.set("active", false)
	_reconnect_bridge()

# The audit owns the seam for the lane (the scenario precedent).
func _disconnect_bridge() -> void:
	var target := Callable(_runtime(), "_on_entity_encounter")
	if _runtime().overworld_mons_runtime.encounter_requested.is_connected(target):
		_runtime().overworld_mons_runtime.encounter_requested.disconnect(target); _bridge_disconnected = true
func _reconnect_bridge() -> void:
	var target := Callable(_runtime(), "_on_entity_encounter")
	if _bridge_disconnected and not _runtime().overworld_mons_runtime.encounter_requested.is_connected(target):
		_runtime().overworld_mons_runtime.encounter_requested.connect(target); _bridge_disconnected = false
func _check_movement_probe(tile: Vector2i) -> void:
	var result: Dictionary = await _spatial.movement_probe(_world(), _player(), _runtime(), _runner, tile)
	movement_checked += int(result["movement"])
	spatial_checked += int(result["spatial"])
	_failures.append_array(result["failures"])
func _reset(mons) -> void: # the scenario harness reset (a fresh derivation at the current steps)
	mons._entities.clear(); mons._removed.clear(); mons._nests_found.clear(); mons._pool_cache.clear()
	mons._pending = {}; mons._pending_id = ""; mons._last_battle_was_entity = false
	mons._time_label = ""; mons._faced_tile = Vector2i.MAX; mons._last_interact_id = ""; mons._last_interact_step = -100
func _ensure_named(named: Dictionary, species_id: String, disposition: String, biome: String) -> void:
	if not named.has(species_id): return # presence is the scenario's pin; correctness is checked where seen
	var entry: Array = named[species_id]
	if biome != "" and str(entry[0]) != biome: return # the wiki gate is biome-conditioned
	if str(entry[1]) != disposition:
		_failures.append({"kind": "entity_wiki_disposition", "species_id": species_id, "disposition": str(entry[1]), "want": disposition})
func _species_sheet_path(species_id: String) -> String:
	var path := str(_runtime().catalog.get_species(species_id).get("overworld_path", ""))
	return path if not path.is_empty() else NOT_FOUND_PATH
func _atlas_path(sprite: Sprite2D) -> String: # entity sprites are AtlasTextures over the species sheet
	var texture: Texture2D = sprite.texture
	if texture is AtlasTexture and (texture as AtlasTexture).atlas != null:
		return (texture as AtlasTexture).atlas.resource_path
	return texture.resource_path if texture != null else ""
func _entity_layer() -> Node:
	var parent := _player().get_parent()
	return parent.get_node_or_null("EntityLayer") if parent != null else null
func _mons() -> Object:
	var runtime := _runtime()
	var value: Variant = runtime.get("overworld_mons_runtime") if runtime != null and "overworld_mons_runtime" in runtime else null
	return value if value is Object else null
func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
