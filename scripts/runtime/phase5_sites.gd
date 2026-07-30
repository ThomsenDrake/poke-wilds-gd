extends RefCounted

# Site / pen / water / material helpers for the Phase 5 scenarios (breed_flow /
# habitat_drops / fishing_flow / shiny_odds; spec: docs/product-specs/
# breeding-shinies-drops-fishing.md). Pure use of EXISTING Phase 1/2 surfaces:
# a pen is a Phase-1 FENCE ring around a 3x3 interior (fences are solid, so the
# flood fills only when a gate opens it — faithful); the enclosure proof is the
# world_generator.reachable_walkable_count primitive the runtimes reuse.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const FENCE_ID := "fence"
const PEN_RADIUS := 1 # 3x3 interior around the center; a 5x5 placeable block.
const PEN_BUDGET := 25 # flood-fill budget; an enclosed 3x3 returns 9 < 25.
# Fences price log+dry_soil only in non-desert biomes (structures.gd cost_for);
# the desert stone shell would need hard_stone, which the witnessed drop economy
# never yields (material_drops.gd + habitat_drops.gd witness invariant).
const PEN_BIOMES := ["PLAINS", "GRASSLAND", "FOREST", "SAVANNA", "SWAMP", "ROCK", "SNOW", "LAVA"]


# Center of the first 5x5 block (ring order from `start`) whose tiles are all
# open ground sharing one non-desert biome with NO tall grass anywhere in the
# interior + fence ring + habitat scan ring (the unsatisfied-control pens must
# stay grass-free); Vector2i.ZERO when none is found. Vector2i.ZERO is the
# not-found SENTINEL: scans start at the player (world 0,0 lies far outside any
# spawn's scan) and a site needs a prop-free 5x5, so a real site at (0,0) is
# effectively impossible — the failure mode is a LOUD named red, never silent.
static func find_pen_site(world, start: Vector2i, scan_radius: int) -> Vector2i:
	var runner := SmokeScenarioRunner.new()
	for ring in range(0, scan_radius + 1):
		for center in runner.ring_around(start, ring):
			if _pen_block_placeable(world, center):
				return center
	return Vector2i.ZERO


# Center of a pen built AROUND a habitat feature (real PokeWilds pens enclose a
# tree/pond): the CENTER tile is a tree prop ("tree" tag) when `feature` is
# "tree" or a WATER-biome tile ("deep_water") when "water" — solid/unwalkable, so
# the interior flood excludes it while the shared ring scan catches it (Major-1
# proof). The 5x5 (interior ring + fences) must be clean open ground and the
# stand ring walkable, all of one non-desert biome; Vector2i.ZERO when none
# (the SAME not-found sentinel as find_pen_site — see its note).
static func find_feature_pen_site(world, start: Vector2i, scan_radius: int, feature: String) -> Vector2i:
	var runner := SmokeScenarioRunner.new()
	for ring in range(1, scan_radius + 1):
		for center in runner.ring_around(start, ring):
			if _feature_pen_placeable(world, center, feature):
				return center
	return Vector2i.ZERO


# Fences the ring around `center` (PEN_RADIUS interior) and invalidates the
# breeding runtime's region cache (when the helper is passed). {"ok", "fences",
# "reason"}; refuses on any placement failure or a non-enclosing ring.
static func build_pen(runtime, center: Vector2i, invalidate: Callable = Callable()) -> Dictionary:
	var placed := 0
	for tile in fence_ring(center):
		var result: Dictionary = runtime.build_runtime.try_place(tile, FENCE_ID, {})
		if not bool(result.get("ok", false)):
			return {"ok": false, "fences": placed, "reason": "fence refused at %s (%s)" % [str(tile), str(result.get("reason", ""))]}
		placed += 1
	if invalidate.is_valid():
		invalidate.call()
	if not is_pen_enclosed(runtime, _enclosure_probe(runtime, center)):
		return {"ok": false, "fences": placed, "reason": "fence ring did not enclose the interior"}
	return {"ok": true, "fences": placed, "reason": ""}


static func demolish_pen(runtime, center: Vector2i, invalidate: Callable = Callable()) -> void:
	for tile in fence_ring(center):
		runtime.build_runtime.try_demolish(tile, {})
	if invalidate.is_valid():
		invalidate.call()


# Enclosure proof: the flood fill from the interior center cannot escape the
# fence ring (count < budget).
static func is_pen_enclosed(runtime, center: Vector2i) -> bool:
	return int(runtime._world_gen.reachable_walkable_count(center, PEN_BUDGET)) < PEN_BUDGET


# Feature-pen centers are solid/unwalkable (the whole point): a flood starting
# there returns 0 and proves nothing, so enclosure is probed from the first
# WALKABLE interior neighbor; standard pens probe the center itself.
static func _enclosure_probe(runtime, center: Vector2i) -> Vector2i:
	for candidate in [center, center + Vector2i.RIGHT, center + Vector2i.DOWN, center + Vector2i.LEFT, center + Vector2i.UP]:
		if bool(runtime._world_gen.get_tile_logic(candidate).get("walkable", false)):
			return candidate
	return center


static func fence_ring(center: Vector2i) -> Array:
	var tiles: Array = []
	var outer := PEN_RADIUS + 1
	for dy in range(-outer, outer + 1):
		for dx in range(-outer, outer + 1):
			if maxi(absi(dx), absi(dy)) == outer:
				tiles.append(center + Vector2i(dx, dy))
	return tiles


# Stand/faced pair for the fence-Z seam: stand one tile outside the ring, face
# the fence (the runtime reads the interior tile beyond it). {} when landlocked.
static func pen_stand_spot(world, center: Vector2i) -> Dictionary:
	for direction in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
		var stand: Vector2i = center + direction * (PEN_RADIUS + 2)
		var faced: Vector2i = center + direction * (PEN_RADIUS + 1)
		if world.is_tile_walkable(stand):
			return {"stand": stand, "faced": faced}
	return {}


# First open-ground tile near `center` (campfire siting; craft_flow pattern).
# Not-found = Vector2i.MAX (NEVER ZERO — (0,0) is a real open tile; the ZERO sentinel
# conflated a found origin tile with "not found").
static func find_open_tile(world, center: Vector2i, radius: int) -> Vector2i:
	var runner := SmokeScenarioRunner.new()
	for ring in range(1, radius + 1):
		for tile in runner.ring_around(center, ring):
			var logic: Dictionary = world.get_tile_logic(tile)
			if bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
				and str(logic.get("structure_id", "")).is_empty() \
				and str(logic.get("landmark_id", "")).is_empty(): # footprints are immutable (can_place_on refuses them, so "open" ground may not overlap one — _pen_block_placeable agrees)
				return tile
	return Vector2i.MAX


# First WATER-biome tile with a walkable stand neighbor {"tile", "stand",
# "direction"}; {} when no water lies within `scan_radius` rings.
static func find_water_tile(world, start: Vector2i, scan_radius: int) -> Dictionary:
	var runner := SmokeScenarioRunner.new()
	for ring in range(1, scan_radius + 1):
		for tile in runner.ring_around(start, ring):
			if str(world.get_tile_logic(tile).get("biome", "")) != "WATER":
				continue
			for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
				var stand: Vector2i = tile + direction
				var stand_logic: Dictionary = world.get_tile_logic(stand)
				if bool(stand_logic.get("walkable", false)) and str(stand_logic.get("biome", "")) != "WATER":
					return {"tile": tile, "stand": stand, "direction": -direction}
	return {}


# Exact fence need for one pen (ring size x {log:1, dry_soil:1}), drained first
# so leftover bag state can never skew the exact-delta assertions.
static func grant_pen_materials(runtime) -> void:
	var count := fence_ring(Vector2i.ZERO).size()
	for item_id in ["log", "dry_soil"]:
		runtime.session.remove_item(item_id, runtime.get_item_count(item_id))
		runtime.session.add_item(item_id, count)


# Campfire + the full rod chain's ingredients (recipes.gd exact): campfire
# 4 log + 2 dry_soil, old_rod 1 log + 1 silky_thread, good_rod 2 metal_coat,
# super_rod 3 magnet — drained first like grant_pen_materials.
static func grant_rod_materials(runtime) -> void:
	# Rods too: a loaded save may carry crafted rods (the exact-craft asserts
	# drain-then-grant, craft_flow pattern).
	for item_id in ["log", "dry_soil", "silky_thread", "metal_coat", "magnet", "old_rod", "good_rod", "super_rod"]:
		runtime.session.remove_item(item_id, runtime.get_item_count(item_id))
	for entry in [["log", 5], ["dry_soil", 2], ["silky_thread", 1], ["metal_coat", 2], ["magnet", 3]]:
		runtime.session.add_item(str(entry[0]), int(entry[1]))


# NOTE: reads get_tile_logic (global generator mirror), NOT get_tile_biome —
# the biome accessor reads the render cache and is empty outside the synced
# window; site scans reach far beyond it.
static func _pen_block_placeable(world, center: Vector2i) -> bool:
	var biome := str(world.get_tile_logic(center).get("biome", ""))
	if not PEN_BIOMES.has(biome):
		return false
	var outer := PEN_RADIUS + 2 # interior + fence ring + the habitat scan ring
	for dy in range(-outer, outer + 1):
		for dx in range(-outer, outer + 1):
			var logic: Dictionary = world.get_tile_logic(center + Vector2i(dx, dy))
			if str(logic.get("biome", "")) != biome or str(logic.get("tall_grass_path", "")) != "":
				return false
			if maxi(absi(dx), absi(dy)) <= PEN_RADIUS + 1: # the placeable 5x5 must be open ground
				if not bool(logic.get("walkable", false)) or not str(logic.get("prop_path", "")).is_empty() \
					or not str(logic.get("structure_id", "")).is_empty() \
					or not str(logic.get("landmark_id", "")).is_empty(): # landmark footprints are immutable (Build 1's can_place_on refuses them, so a pen site may not overlap one)
					return false
	return true


# Feature-pen siting: the center carries the feature (the SAME prop/biome tests
# habitat_drops.tile_habitat_tags reads — tree1/tree13 suffixes, WATER biome).
# The 5x5 (interior ring + fence ring) must be clean open ground (fences price
# log+dry_soil on prop-free walkable tiles) and the stand ring merely walkable —
# tree biomes (GRASSLAND/FOREST/SWAMP/SNOW) are prop-dense, so a grass/flower-
# clean 7x7 effectively never occurs; extra habitat tags are harmless here (the
# unsatisfied-control grass-free rule belongs to the standard pens only).
static func _feature_pen_placeable(world, center: Vector2i, feature: String) -> bool:
	var center_logic: Dictionary = world.get_tile_logic(center)
	var prop := str(center_logic.get("prop_path", ""))
	var is_feature := (feature == "tree" and (prop.ends_with("tree1.png") or prop.ends_with("tree13.png"))) \
		or (feature == "water" and str(center_logic.get("biome", "")) == "WATER")
	if not is_feature:
		return false
	var biome := ""
	var outer := PEN_RADIUS + 2
	for dy in range(-outer, outer + 1):
		for dx in range(-outer, outer + 1):
			if dx == 0 and dy == 0:
				continue
			var logic: Dictionary = world.get_tile_logic(center + Vector2i(dx, dy))
			var tile_biome := str(logic.get("biome", ""))
			if biome.is_empty():
				if not PEN_BIOMES.has(tile_biome):
					return false
				biome = tile_biome
			elif tile_biome != biome:
				return false
			if not bool(logic.get("walkable", false)) or not str(logic.get("structure_id", "")).is_empty():
				return false
			if maxi(absi(dx), absi(dy)) <= PEN_RADIUS + 1 \
				and (not str(logic.get("prop_path", "")).is_empty() or not str(logic.get("landmark_id", "")).is_empty()): # the placeable 5x5 may not overlap a footprint (can_place_on refuses fence on one — _pen_block_placeable agrees)
				return false
	return true
