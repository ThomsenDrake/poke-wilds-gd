extends RefCounted

# Legendary dungeon dimensions — the PURE parsed-cell API over dungeon_layouts.gd's const
# ASCII maps (plan: legendary_dungeon_dimensions; spec: docs/product-specs/world-depth.md §
# Legendaries). Mirrors the Landmarks cell grammar EXACTLY ({walkable, encounter, token, prop,
# region, reason} — landmarks.gd:276) so a later runtime can stamp dungeon cells through the
# same tile-logic seam. Also owns: the species<->dungeon mapping, the entrance-anchor
# derivation (DELEGATING to LegendaryPlacement.legendaries_for_world with an EMPTY removals
# array — the sibling-exclusion chain there keeps anchors byte-identical to the legendary_spawn
# pins, and entrances stamp even after a catch), the warp-tile tables (entrance warp ->
# dungeon spawn; dungeon exit -> entrance warp), the per-dungeon curated encounter scopes
# (dungeon_layouts.gd SCOPES — NEVER a legendary), and the pure map invariants (flood-fill
# reachability, exactly one exit, chamber exists).
# NO RandomNumberGenerator / engine hash() / dict-iteration-order dependence / I/O.

const DungeonLayouts := preload("res://scripts/domain/dungeon_layouts.gd")
const LegendaryPlacement := preload("res://scripts/domain/legendary_placement.gd")

const DUNGEON_IDS := [ # pinned order: the LegendaryPlacement.LEGENDARY_IDS roster order
	"dungeon_mewtwo", "dungeon_regirock", "dungeon_regice", "dungeon_registeel",
	"dungeon_regieleki", "dungeon_regidrago", "dungeon_regigigas",
]
const REGIONS := ["entry", "hall", "chamber", "exit", "wall"] # the canonical region set
const EXIT_SOUTH_BAND := 2 # the exit warp must sit within this many rows of the south edge
const _GRAMMAR := "#~.,;SEPxXtTdD" # the one-char grid alphabet (dungeon_layouts.gd legend)

# Parse cache: a pure function of the const grids, computed once per id (the Landmarks
# _world_cache precedent — single-key access, never feeds any derivation).
static var _map_cache: Dictionary = {}
# Entrances cache: a pure function of the world_seed ONLY (legendaries_for_world rides an
# EMPTY removals array — entrance stamps persist after a catch). Without it the per-tile
# resolver re-ran the seven-species anchor derivation on EVERY overworld tile query.
static var _entrances_cache: Dictionary = {}


# --- Roster mapping ---------------------------------------------------------------
static func is_dungeon(dungeon_id: String) -> bool:
	return DUNGEON_IDS.has(dungeon_id)

static func dungeon_for_species(species_id: String) -> String: # "" when the species has no dungeon
	for dungeon_id in DUNGEON_IDS:
		if str(DungeonLayouts.DUNGEONS[dungeon_id]["species"]) == species_id:
			return dungeon_id
	return ""

static func species_for_dungeon(dungeon_id: String) -> String: # "" when unknown
	if not is_dungeon(dungeon_id):
		return ""
	return str(DungeonLayouts.DUNGEONS[dungeon_id]["species"])


# --- Parsed maps ------------------------------------------------------------------
# map_for: {dungeon_id, name, species_id, size, token, cells: {Vector2i: cell}, spawn, exit,
# chamber, regions}. Cells carry the landmarks grammar {walkable, encounter, token, prop,
# region, reason}; the encounter token stamps ONLY on ',' cells (encounter=true).
static func map_for(dungeon_id: String) -> Dictionary: # the AUDIT path: the one defensive deep copy
	return _cached(dungeon_id).duplicate(true)

static func cell_for(dungeon_id: String, local: Vector2i) -> Dictionary: # {} outside the map
	return (_cached(dungeon_id).get("cells", {}) as Dictionary).get(local, {})

static func spawn_tile_for(dungeon_id: String) -> Vector2i: # the entrance-warp landing tile
	return _cached(dungeon_id).get("spawn", Vector2i.ZERO)

static func exit_tile_for(dungeon_id: String) -> Vector2i: # the dungeon-local exit warp tile
	return _cached(dungeon_id).get("exit", Vector2i.ZERO)

static func chamber_tile_for(dungeon_id: String) -> Vector2i: # the legendary's pedestal tile
	return _cached(dungeon_id).get("chamber", Vector2i.ZERO)

# The hot-path read: parse-on-miss off the WRITE-ONCE cache, NO deep copy (no caller mutates the returned cells).
static func _cached(dungeon_id: String) -> Dictionary:
	if not is_dungeon(dungeon_id):
		push_warning("DungeonMaps: unknown dungeon id '%s'" % dungeon_id)
		return {}
	if not _map_cache.has(dungeon_id):
		_map_cache[dungeon_id] = _parse(dungeon_id)
	return _map_cache[dungeon_id]


# --- Entrances (overworld stamps at the LEGENDARY anchors) --------------------------
# The derivation delegates to legendaries_for_world with removals = [] — entrances ALWAYS
# stamp, even after the catch writes its removal; the sibling-exclusion chain inside keeps
# the anchors byte-identical to today's legendary_spawn pins. Species whose affinity pocket
# the reach box lacks resolve NO_ANCHOR upstream and simply stamp NO entrance.
static func entrances_for_world(world_seed: int) -> Array:
	if not _entrances_cache.has(world_seed):
		_entrances_cache[world_seed] = _derive_entrances(world_seed)
	return (_entrances_cache[world_seed] as Array).duplicate(true)

static func _derive_entrances(world_seed: int) -> Array:
	var by_species: Dictionary = {}
	for entry in LegendaryPlacement.legendaries_for_world(world_seed, Vector2i.ZERO, []):
		by_species[str(entry["species_id"])] = entry
	var out: Array = []
	for species_id in LegendaryPlacement.LEGENDARY_IDS: # the pinned roster order
		if not by_species.has(species_id):
			continue
		var anchor: Vector2i = by_species[species_id]["tile"]
		var dungeon_id := dungeon_for_species(species_id)
		out.append({
			"dungeon_id": dungeon_id, "species_id": species_id,
			"anchor": anchor, "warp_tile": anchor, # the warp tile SITS ON the anchor
			"footprint": Rect2i(anchor - DungeonLayouts.ENTRANCE_WARP_LOCAL, DungeonLayouts.ENTRANCE_SIZE),
			"ring": int(by_species[species_id]["ring"]),
		})
	return out

static func entrance_anchor_for(world_seed: int, species_id: String) -> Vector2i: # NO_ANCHOR when absent
	for entrance in entrances_for_world(world_seed):
		if str(entrance["species_id"]) == species_id:
			return entrance["anchor"]
	return LegendaryPlacement.NO_ANCHOR

# The entrance cell at a WORLD tile ({} outside every facade), carrying the landmarks grammar
# plus dungeon_id + warp flag so the runtime stamp needs no second lookup. Facades may OVERLAP
# (the sibling-exclusion chain keeps anchor TILES distinct, not 5x4 footprints), so the warp
# tile wins by ANCHOR-EXACT priority — a facade can never swallow a sibling's warp tile;
# non-anchor overlap cells resolve to the roster-first facade (cosmetic frame tiles only).
static func entrance_cell_for(world_seed: int, map_pos: Vector2i) -> Dictionary:
	var entrances := entrances_for_world(world_seed)
	for entrance in entrances: # pass 1: anchor-exact (the warp tile)
		if entrance["anchor"] == map_pos:
			return _stamped_entrance_cell(entrance, DungeonLayouts.ENTRANCE_WARP_LOCAL)
	for entrance in entrances: # pass 2: first facade containing the tile
		if (entrance["footprint"] as Rect2i).has_point(map_pos):
			return _stamped_entrance_cell(entrance, map_pos - (entrance["footprint"] as Rect2i).position)
	return {}

static func _stamped_entrance_cell(entrance: Dictionary, local: Vector2i) -> Dictionary:
	var cell := _entrance_cell(str(entrance["species_id"]), local)
	cell["dungeon_id"] = str(entrance["dungeon_id"])
	cell["warp"] = local == DungeonLayouts.ENTRANCE_WARP_LOCAL
	return cell

static func entrance_layout_for(dungeon_id: String) -> Dictionary: # {size, cells, warp} — {} when unknown
	if not is_dungeon(dungeon_id):
		return {}
	var species_id := species_for_dungeon(dungeon_id)
	var cells: Dictionary = {}
	for y in range(DungeonLayouts.ENTRANCE_SIZE.y):
		for x in range(DungeonLayouts.ENTRANCE_SIZE.x):
			cells[Vector2i(x, y)] = _entrance_cell(species_id, Vector2i(x, y))
	return {"size": DungeonLayouts.ENTRANCE_SIZE, "cells": cells, "warp": DungeonLayouts.ENTRANCE_WARP_LOCAL}


# --- Warp tables --------------------------------------------------------------------
# Entrance warp tile (world) -> dungeon spawn tile (dungeon-local). {} off a warp tile.
static func warp_into_dungeon(world_seed: int, map_pos: Vector2i) -> Dictionary:
	var cell := entrance_cell_for(world_seed, map_pos)
	if cell.is_empty() or not bool(cell.get("warp", false)):
		return {}
	var dungeon_id := str(cell["dungeon_id"])
	return {"dungeon_id": dungeon_id, "tile": spawn_tile_for(dungeon_id), "entrance_tile": map_pos}

# Dungeon exit tile (dungeon-local) -> the entrance warp tile (world). {} when unknown/absent.
static func warp_out_of_dungeon(dungeon_id: String, world_seed: int) -> Dictionary:
	var anchor := entrance_anchor_for(world_seed, species_for_dungeon(dungeon_id))
	return {} if anchor == LegendaryPlacement.NO_ANCHOR else {"tile": anchor}


# --- Encounter scopes ---------------------------------------------------------------
# The per-dungeon curated scope for the landmark token seam (encounter_scope_for / extra_ids
# / curated — landmark_runtime.gd:159-206); data lives in dungeon_layouts.gd SCOPES. {} for
# unknown ids; extra_ids derive from the curated keys.
static func encounter_scope_for(dungeon_id: String) -> Dictionary:
	return DungeonLayouts.normalized_encounter_scope(dungeon_id)


# --- Pure map invariants ------------------------------------------------------------
# validate_map: [] when the dungeon honors every invariant, else LOUD issue strings (the
# world_gen_dungeons audit lane asserts these are empty). Never mutates, never warns.
static func validate_map(dungeon_id: String) -> Array:
	var issues: Array = []
	if not is_dungeon(dungeon_id):
		return ["unknown dungeon id '%s'" % dungeon_id]
	var grid: Array = DungeonLayouts.DUNGEONS[dungeon_id]["grid"]
	var width := str(grid[0]).length()
	var counts := {"S": 0, "E": 0, "P": 0} # the spawn/exit/pedestal structural markers
	for row in grid: # ragged/unknown-char + the marker counts ride ONE pass (LOUD, never silent)
		if str(row).length() != width:
			issues.append("ragged grid row (width %d != %d)" % [str(row).length(), width])
		for i in range(str(row).length()):
			var ch := str(row).substr(i, 1)
			if not _GRAMMAR.contains(ch):
				issues.append("unknown grid char '%s'" % ch)
			elif counts.has(ch):
				counts[ch] = int(counts[ch]) + 1
	var map := map_for(dungeon_id)
	var size: Vector2i = map["size"]
	var cells: Dictionary = map["cells"]
	var spawn: Vector2i = map["spawn"]
	var exit: Vector2i = map["exit"]
	var chamber: Vector2i = map["chamber"]
	# Exactly one of each marker: the maps are FIXED data, so a duplicate/missing marker is a
	# defect, never a design choice (_parse's last-wins would mask it; sinks the old MAX checks).
	for marker in ["S", "E", "P"]:
		if int(counts[marker]) != 1:
			issues.append("exactly one '%s' spawn/exit/pedestal marker required (found %d)" % [marker, int(counts[marker])])
	if exit != Vector2i.MAX and exit.y < size.y - EXIT_SOUTH_BAND:
		issues.append("exit warp not near the south edge (y=%d of %d)" % [exit.y, size.y])
	if issues.is_empty():
		var reached := _flood_fill(cells, size, spawn)
		if not reached.has(chamber):
			issues.append("chamber tile unreachable from spawn")
		if not reached.has(exit):
			issues.append("exit warp unreachable from spawn")
		for y in range(size.y): # no orphan pockets: EVERY walkable cell is reachable
			for x in range(size.x):
				var tile := Vector2i(x, y)
				if bool((cells[tile] as Dictionary)["walkable"]) and not reached.has(tile):
					issues.append("walkable cell unreachable from spawn: %s" % str(tile))
	var scope := encounter_scope_for(dungeon_id)
	if (scope.get("curated", {}) as Dictionary).is_empty(): issues.append("curated encounter table must not be empty")
	for species_id in scope.get("curated", {}):
		if LegendaryPlacement.LEGENDARY_IDS.has(str(species_id)):
			issues.append("curated scope carries a legendary: %s" % str(species_id))
	return issues

static func validate_all() -> Dictionary: # {dungeon_id: [issues]} — every value empty when clean
	var out: Dictionary = {}
	for dungeon_id in DUNGEON_IDS: out[dungeon_id] = validate_map(dungeon_id)
	return out

# --- Parse + flood fill (private) ----------------------------------------------------
static func _parse(dungeon_id: String) -> Dictionary:
	var def: Dictionary = DungeonLayouts.DUNGEONS[dungeon_id]
	var grid: Array = def["grid"]
	var theme: Dictionary = def["theme"]
	var size := Vector2i(str(grid[0]).length(), grid.size())
	var cells: Dictionary = {}
	var spawn := Vector2i.MAX; var exit := Vector2i.MAX; var chamber := Vector2i.MAX
	for y in range(size.y):
		var row := str(grid[y])
		for x in range(size.x):
			var tile := Vector2i(x, y)
			var ch := row.substr(x, 1)
			cells[tile] = _cell(ch, theme, dungeon_id)
			if ch == "S": spawn = tile
			elif ch == "E": exit = tile
			elif ch == "P": chamber = tile
	return {"dungeon_id": dungeon_id, "name": str(def["name"]), "species_id": str(def["species"]),
		"size": size, "token": dungeon_id, "cells": cells, "spawn": spawn, "exit": exit,
		"chamber": chamber, "regions": REGIONS.duplicate()}

# The one-char grammar -> the landmarks cell shape; unknown chars parse as a wall (validate_map
# owns the LOUD refusal — a blocked fallback tile never leaks the player out of the map).
static func _cell(ch: String, theme: Dictionary, token: String) -> Dictionary:
	match ch:
		"#":
			return _make(false, false, "", str(theme["wall"]), "wall", str(theme["wall_reason"]))
		"~":
			return _make(true, false, "", str(theme["floor"]), "entry")
		".":
			return _make(true, false, "", str(theme["floor"]), "hall")
		",":
			return _make(true, true, token, str(theme["floor"]), "hall")
		";":
			return _make(true, false, "", str(theme["floor"]), "chamber")
		"S":
			return _make(true, false, "", str(theme["floor"]), "entry")
		"E":
			return _make(true, false, "", "res://assets/source/tiles/warp_tile1.png", "exit")
		"P":
			return _make(true, false, "", str(theme["pedestal"]), "chamber")
		"x":
			return _make(false, false, "", str(theme["ledge"]), "hall", str(theme["ledge_reason"]))
		"X":
			return _make(false, false, "", str(theme["ledge"]), "chamber", str(theme["ledge_reason"]))
		"t":
			return _make(false, false, "", str(theme["prop"]), "hall", str(theme["prop_reason"]))
		"T":
			return _make(false, false, "", str(theme["prop"]), "chamber", str(theme["prop_reason"]))
		"d":
			return _make(true, false, "", str(theme["drift"]), "hall")
		"D":
			return _make(true, false, "", str(theme["drift"]), "chamber")
	return _make(false, false, "", str(theme["wall"]), "wall", str(theme["wall_reason"]))

static func _entrance_cell(species_id: String, local: Vector2i) -> Dictionary:
	var grid: Array = DungeonLayouts.ENTRANCE_GRID_SEALED if species_id == "REGIGIGAS" else DungeonLayouts.ENTRANCE_GRID
	var ch := str(grid[local.y]).substr(local.x, 1)
	var framing: Dictionary = DungeonLayouts.ENTRANCE_FRAME[LegendaryPlacement.affinity_for(species_id)]
	match ch:
		"F":
			return _make(false, false, "", str(framing["frame"]), "entrance", "The cave face blocks the way.")
		"M":
			return _make(false, false, "", DungeonLayouts.ENTRANCE_MOUTH, "entrance", "A dark cave mouth.")
		"W":
			return _make(true, false, "", DungeonLayouts.ENTRANCE_WARP, "entrance")
		"B":
			return _make(false, false, "", DungeonLayouts.ENTRANCE_BRAILLE, "entrance", "Strange raised markings seal the way.")
	return _make(true, false, "", str(framing["floor"]), "entrance")

static func _flood_fill(cells: Dictionary, size: Vector2i, start: Vector2i) -> Dictionary: # {tile: true}
	var reached := {start: true}
	var stack: Array = [start]
	while not stack.is_empty():
		var tile: Vector2i = stack.pop_back()
		for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var next: Vector2i = tile + direction
			if reached.has(next) or next.x < 0 or next.y < 0 or next.x >= size.x or next.y >= size.y:
				continue
			if not bool((cells[next] as Dictionary)["walkable"]):
				continue
			reached[next] = true
			stack.append(next)
	return reached

static func _make(walkable: bool, encounter: bool, token: String, prop: String, region: String, reason: String = "") -> Dictionary:
	return {"walkable": walkable, "encounter": encounter, "token": token, "prop": prop, "region": region, "reason": reason}
