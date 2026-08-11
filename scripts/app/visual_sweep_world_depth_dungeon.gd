extends RefCounted

# Legendary-dungeon frames for the world_depth sweep (the legendary-dungeon slice; spec:
# docs/product-specs/world-depth.md § Legendaries), extracted at the app-220 wall — a static
# run(sweep) reaching into the sweep node for the shared plumbing (the WorldDepthExpand
# precedent). (44) the overworld entrance FACADE (the 5x4 cave mouth stamped at the pinned
# anchor — the warp stamp + mouth prop live-asserted through the resolver pre-capture) and
# (45) the dungeon INTERIOR chamber (the pedestal tile with the chamber legendary standing
# on it — the entity layer opted IN for this one shot, the retired 36_legendary_guardian
# pattern through WorldDepthExpand.set_entities_active + the shared rest probe; the player
# re-homes OFF the warp tile on exit so the sweep tail can never re-arm the entry step).
# The dungeon is DISCOVERED, never hand-picked: the first pinned-roster species whose anchor
# resolves under the crafted seed, the tablet-gated seal dungeon excluded (the crafted bag
# is empty, so its warp would refuse). Regions ride the oracle's DYNAMIC seam (the retired
# chained/guardian shots' pattern — the ink tiles are derived per map, never hard-coded);
# the interior shot is ink-only (the chamber entity sprite's idle-frame strictness is
# unproven — the 34_heart_tower proportionate tier, visual_region_diff.py:40). NO rng: the
# maps are const data, the anchor derivation is pure, the same seed always picks the same
# dungeon — byte-stable captures.

const DungeonRuntime := preload("res://scripts/runtime/dungeon_runtime.gd") # rides its domain preloads (the layer table; the legendary_dungeon_scenario precedent)
const WorldDepthOracle := preload("res://scripts/app/visual_sweep_world_depth_oracle.gd")
const WorldDepthExpand := preload("res://scripts/app/visual_sweep_world_depth_expand.gd")
const DungeonMaps := DungeonRuntime.DungeonMaps
const DungeonLayouts := DungeonRuntime.DungeonLayouts
const LegendaryPlacement := DungeonRuntime.LegendaryPlacement

const SHOT_ENTRANCE := "44_dungeon_entrance.png"
const SHOT_INTERIOR := "45_dungeon_interior.png"
const APPROACH_OFFSET := Vector2i(0, 1) # the facade's south approach floor (the scenario's real-step lane stands here)


# Runs the dungeon pair on the sweep node (after the landmark shots). Loud-fails on the sweep.
static func run(sweep: Node) -> void:
	var pick := _pick_dungeon(sweep)
	if pick.is_empty():
		return
	await _entrance_shot(sweep, pick)
	await _interior_shot(sweep, pick)


# The first pinned-roster species whose entrance anchor resolves under the crafted seed.
static func _pick_dungeon(sweep: Node) -> Dictionary:
	var seed := int(sweep._crafted.get("world_seed", 0))
	for species in LegendaryPlacement.LEGENDARY_IDS:
		var dungeon_id := DungeonMaps.dungeon_for_species(str(species))
		if dungeon_id == "" or dungeon_id == DungeonLayouts.SEAL_DUNGEON:
			continue
		var anchor: Vector2i = DungeonMaps.entrance_anchor_for(seed, str(species))
		if anchor != LegendaryPlacement.NO_ANCHOR:
			return {"species_id": str(species), "dungeon_id": dungeon_id, "anchor": anchor}
	sweep._failures.append("%s/%s: no anchored unsealed dungeon under the crafted seed (the anchor derivation regressed)" % [SHOT_ENTRANCE, SHOT_INTERIOR])
	return {}


# (44) The entrance facade: the player on the south approach floor, the cave mouth above.
static func _entrance_shot(sweep: Node, pick: Dictionary) -> void:
	var anchor: Vector2i = pick["anchor"]
	var dungeon_id := str(pick["dungeon_id"])
	var live: Dictionary = sweep._world().get_tile_logic(anchor)
	if not (bool(live.get("walkable", false)) and bool(live.get("dungeon_warp", false)) and str(live.get("dungeon_id", "")) == dungeon_id):
		sweep._failures.append("%s: the live warp stamp at %s drifted (%s)" % [SHOT_ENTRANCE, anchor, live]); return
	var mouth := anchor + Vector2i(0, -1) # the mouth sits one row over the warp (the facade grid)
	var mouth_logic: Dictionary = sweep._world().get_tile_logic(mouth)
	if bool(mouth_logic.get("walkable", true)) or str(mouth_logic.get("prop_path", "")) == "":
		sweep._failures.append("%s: the cave mouth at %s lost its blocked prop (%s)" % [SHOT_ENTRANCE, mouth, mouth_logic]); return
	var ink: Array = [] # every blocked facade cell + the warp tile (its door texture is the base)
	var layout: Dictionary = DungeonMaps.entrance_layout_for(dungeon_id)
	var facade_pos: Vector2i = anchor - (layout["warp"] as Vector2i)
	for local in layout["cells"]:
		if local == layout["warp"] or not bool((layout["cells"][local] as Dictionary).get("walkable", true)):
			ink.append(facade_pos + (local as Vector2i))
	var player_tile := anchor + APPROACH_OFFSET
	sweep._crafted["dungeon_entrance"] = {"dungeon_id": dungeon_id, "species_id": str(pick["species_id"]), "anchor": [anchor.x, anchor.y]}
	sweep._runner.teleport_player(sweep._world(), sweep._player(), sweep._runtime(), player_tile)
	sweep._world().set_time_of_day(int(sweep._crafted["time_of_day"]))
	sweep._world().sync_visible(player_tile)
	sweep._pending_oracle = WorldDepthOracle.dynamic_region(ink, mouth, player_tile, true) # the mouth prop: strict (the mansion-statue class)
	await sweep._capture(SHOT_ENTRANCE)


# (45) The interior: enter through the runtime warp, stand on the sub-pedestal chamber
# floor, capture the pedestal + the standing chamber legendary, then exit + re-home.
static func _interior_shot(sweep: Node, pick: Dictionary) -> void:
	var runtime = sweep._runtime()
	var dungeon_id := str(pick["dungeon_id"])
	if not runtime.dungeon_runtime.try_enter_at(pick["anchor"]):
		sweep._failures.append("%s: try_enter_at refused %s under an empty bag (the seal leaked onto a tablet-less dungeon)" % [SHOT_INTERIOR, dungeon_id]); return
	var prior_entities := WorldDepthExpand.set_entities_active(sweep, true) # the chamber legendary renders
	var chamber: Vector2i = DungeonMaps.chamber_tile_for(dungeon_id)
	var player_tile := chamber + Vector2i(0, 1) # the sub-pedestal chamber floor (';' in every map)
	var logic: Dictionary = sweep._world().get_tile_logic(player_tile)
	if not bool(logic.get("walkable", false)) or str(logic.get("dungeon_region", "")) != "chamber":
		sweep._failures.append("%s: the sub-pedestal tile %s lost its chamber floor (%s)" % [SHOT_INTERIOR, player_tile, logic])
	else:
		var ink: Array = [chamber] # the pedestal base + the standing chamber legendary
		for dy in range(-1, 2): # the 5x3 chamber surround: every blocked cell renders a theme prop
			for dx in range(-2, 3):
				var cell: Dictionary = DungeonMaps.cell_for(dungeon_id, chamber + Vector2i(dx, dy))
				if not cell.is_empty() and not bool(cell.get("walkable", true)):
					ink.append(chamber + Vector2i(dx, dy))
		sweep._crafted["dungeon_interior"] = {"dungeon_id": dungeon_id, "species_id": str(pick["species_id"]), "chamber_tile": [chamber.x, chamber.y]}
		sweep._runner.teleport_player(sweep._world(), sweep._player(), runtime, player_tile)
		sweep._world().set_time_of_day(int(sweep._crafted["time_of_day"]))
		sweep._world().sync_visible(player_tile)
		sweep._pending_oracle = WorldDepthOracle.dynamic_region(ink, Vector2i.MAX, player_tile, false) # ink-only (header)
		await sweep._capture(SHOT_INTERIOR)
	WorldDepthExpand.set_entities_active(sweep, prior_entities)
	runtime.dungeon_runtime.exit_dungeon() # session.player_tile re-lands on the entrance warp
	var home: Vector2i = (pick["anchor"] as Vector2i) + APPROACH_OFFSET
	sweep._runner.teleport_player(sweep._world(), sweep._player(), runtime, home) # node+session OFF the warp tile
	sweep._world().sync_visible(home)
