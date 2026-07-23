extends Node

# Deterministic build driver for the visual sweep (spec:
# docs/product-specs/building-and-placement.md). Runs AFTER the battle shots so
# it cannot perturb shots 01-12: swaps to a Build-capable Machop (the crafted
# DECIDUEYE/CHIKORITA cannot Build, so the swap happens last and 07_party_screen
# is unchanged), crafts a fixed material bag, finds the first all-placeable 3x3
# around the fixed spawn in ring order, and stamps a fixed "small house with a
# door" pattern (a roof cap, a wall ring, one door) at fixed tile offsets.
# Determinism = fixed seed -> fixed spawn -> fixed scan order -> fixed tiles ->
# fixed biome -> fixed sprites, so the shots are byte-stable run-to-run. The
# build descriptor rides the sweep's crafted-state sidecar. Overworld structure
# shots are exempt from the art-anchor gate (declared art stages only); a missing
# house site is skipped gracefully, never a push_error (like _sweep_biomes).

const SCAN_RADIUS := 30
# House pattern: offsets from the house center -> structure id. A roof cap on the
# top row, walls down the two sides and the bottom corners, and a door in the
# bottom-middle (the only walkable tile in the ring -> an enclosed interior).
const HOUSE_PATTERN := {
	Vector2i(-1, -1): "roof", Vector2i(0, -1): "roof", Vector2i(1, -1): "roof",
	Vector2i(-1, 0): "wall", Vector2i(1, 0): "wall",
	Vector2i(-1, 1): "wall", Vector2i(0, 1): "door", Vector2i(1, 1): "wall",
}

# Builds the house and captures the new overworld-with-structures shots through
# the sweep's own _capture (so sidecar + reconcile are shared). `crafted` is the
# sweep's mutable crafted-state dict; the build descriptor is recorded into it.
func craft_build(ctx: Dictionary, runner, crafted: Dictionary, capture: Callable) -> void:
	var runtime = ctx["runtime"]
	var world: Node = ctx["world"]
	var party_before: Array = runner.swap_party(runtime, ["MACHOP"])
	runtime.session.add_item("log", 12)
	runtime.session.add_item("dry_soil", 12)
	# hard_stone funds the desert/SAND stone shell (8 shell pieces x 2 = 16) so a future
	# seed that moves spawn onto a stone-shell biome can still raise the whole house;
	# the crafted PLAINS seed never spends it, so the baseline bytes are unchanged.
	runtime.session.add_item("hard_stone", 16)
	var spawn: Vector2i = runtime._world_gen.find_walkable_spawn(runtime.get_world_seed())
	var found := _find_house_center(world, runner, spawn)
	if found.is_empty():
		runtime.warn("VisualSweepBuild", "No placeable 3x3 near spawn; built-house shots skipped.", {"seed": runtime.get_world_seed()})
	else:
		var center: Vector2i = found["center"]
		_place_house(runtime, center)
		crafted["build"] = {"seed": runtime.get_world_seed(), "center": [center.x, center.y],
			"biome": str(world.get_tile_logic(center).get("biome", "")), "pattern": _pattern_payload()}
		# Camera follows the player: stand just south of the door to frame the house.
		runner.teleport_player(world, ctx["player"], runtime, center + Vector2i(0, 2))
		world.sync_visible(center)
		await capture.call("13_built_house.png")
		await _capture_ghost(ctx, center, capture)
	runner.restore_party(runtime, party_before)


# Stamps the fixed pattern at fixed offsets (insertion order is deterministic).
# Every piece must land: a refusal (a future seed moving spawn onto an unfunded
# biome, or an occupancy surprise) would silently yield a partial house shot, so
# it is pushed as an error. A missing SITE stays a graceful skip upstream (craft_build).
func _place_house(runtime, center: Vector2i) -> void:
	for offset in HOUSE_PATTERN.keys():
		var result: Dictionary = runtime.build_runtime.try_place(center + offset, HOUSE_PATTERN[offset], {})
		if not bool(result.get("ok", false)):
			push_error("visual_sweep_build: %s refused at %s (%s); the built-house shot would be partial" % [str(HOUSE_PATTERN[offset]), str(center + offset), str(result.get("reason", ""))])


# Ghost preview mid build-mode on a placeable tile OUTSIDE the house (so the
# translucent preview is visible against open ground, not occluded by the walls).
func _capture_ghost(ctx: Dictionary, center: Vector2i, capture: Callable) -> void:
	var layer = ctx.get("structure_layer")
	var world: Node = ctx["world"]
	var ghost_tile := _ghost_tile(world, center)
	if layer == null or ghost_tile == center:
		return
	layer.start_build(ghost_tile, {})
	await capture.call("14_build_ghost.png")
	layer.stop_build()


# First placeable tile at Chebyshev distance >= 2 from the house center (outside
# the footprint, inside the camera view); {} -> center means none found.
func _ghost_tile(world, center: Vector2i) -> Vector2i:
	for radius in range(2, 6):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if max(abs(dx), abs(dy)) != radius:
					continue
				var tile := center + Vector2i(dx, dy)
				if _placeable(world, tile):
					return tile
	return center


# First 3x3 (by its center) in ring order around spawn whose nine tiles are all
# open ground (walkable, no prop, no placement); {} when none within SCAN_RADIUS.
func _find_house_center(world, runner, spawn: Vector2i) -> Dictionary:
	for radius in range(0, SCAN_RADIUS + 1):
		for tile in runner.ring_around(spawn, radius):
			if _all_placeable(world, tile):
				return {"center": tile}
	return {}


func _all_placeable(world, center: Vector2i) -> bool:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if not _placeable(world, center + Vector2i(dx, dy)):
				return false
	return true


func _placeable(world, tile: Vector2i) -> bool:
	var logic: Dictionary = world.get_tile_logic(tile)
	return bool(logic.get("walkable", false)) and str(logic.get("prop_path", "")).is_empty() \
		and str(logic.get("structure_id", "")).is_empty()


func _pattern_payload() -> Array:
	var out: Array = []
	for offset in HOUSE_PATTERN.keys():
		out.append([offset.x, offset.y, HOUSE_PATTERN[offset]])
	return out
