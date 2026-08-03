extends RefCounted

# Scattered LANDMARK instances (infinite-world slice 3): the chunk-hash derivation for
# content_scatter.gd's rolls — per-chunk anchor search (the proven _fits_on_land/_disjoint
# + budget-400 spiral), WINDOW-bounded enumeration, and the O(1) per-tile consult the
# generator's resolver seam rides. The ORIGIN-CORE three are NOT here: they stay in
# landmarks.gd (landmarks_in_world, byte-identical anchors) — this module only derives
# instances BEYOND the origin core (the slice's pinning discipline: the calibrated origin
# region never moves). landmark_runtime composes the two at the resolver boundary, so
# landmarks.gd never preloads this module (no cycle).
#
# Determinism: every derivation is a pure function of (world_seed, chunk) — _mix rolls +
# FastNoiseLite elevation via the Landmarks helpers; NO rng, NO I/O (the domain ban). The
# per-chunk cache is insertion-order-evicted (never the plane) and pinned to no consumer.

const ContentScatter := preload("res://scripts/domain/content_scatter.gd")
const Landmarks := preload("res://scripts/domain/landmarks.gd")
const BiomeField := preload("res://scripts/domain/biome_field.gd")

# A scattered anchor must sit at ring >= SCATTER_MIN_RING: the world-depth sweep probes
# spiral from origin capped at 80, the origin footprints end by ring ~55, and a footprint
# half-extent is <= 8 — 112 leaves every origin probe + the _outside_tile check untouched.
const SCATTER_MIN_RING := 112
const CHUNK_CACHE_CAP := 256 # insertion-order eviction; an infinite walk can never grow it

# Per-(seed, chunk) derived instance ({} or {"landmark_id", "anchor", "footprint",
# "instance_key"}). Static process-global — pure function of the key, so sharing it across
# the runtime/view/mirror generators is exact (the _world_cache precedent).
static var _chunk_cache: Dictionary = {}
static var _chunk_cache_order: Array = []


# The scattered instance deriving from `chunk` ({} when the chunk has none): the presence
# roll (origin-core suppressed), the kind roll, the margin-kept home tile, then the bounded
# land-fit spiral. Pure; cached per (seed, chunk).
static func instance_for_chunk(world_seed: int, chunk: Vector2i) -> Dictionary:
	var key := "%d:%d,%d" % [world_seed, chunk.x, chunk.y]
	if _chunk_cache.has(key):
		return (_chunk_cache[key] as Dictionary).duplicate(true)
	var entry := _derive(world_seed, chunk)
	_chunk_cache[key] = entry.duplicate(true)
	_chunk_cache_order.append(key)
	while _chunk_cache_order.size() > CHUNK_CACHE_CAP:
		_chunk_cache.erase(_chunk_cache_order.pop_front())
	return entry


# Every scattered instance overlapping a square window around `center_tile` (bounded
# enumeration; the origin three are NOT included — they ride landmarks.landmarks_in_world).
static func instances_in_window(world_seed: int, center_tile: Vector2i, half_extent_tiles: int) -> Array:
	var out: Array = []
	for chunk in ContentScatter.chunks_in_window(center_tile, half_extent_tiles):
		var entry := instance_for_chunk(world_seed, chunk)
		if not entry.is_empty():
			out.append(entry)
	return out


# The scattered consult for one tile: base_logic UNCHANGED outside every footprint (the
# Landmarks.tile_logic_for contract), else the instance's stamped logic via the SINGLE
# cell_logic_for source, plus the additive landmark_instance key. landmark_runtime composes
# this with the origin-three consult at the resolver boundary.
static func tile_logic_for_window(world_seed: int, map_pos: Vector2i, base_logic: Dictionary) -> Dictionary:
	var entry := instance_for_chunk(world_seed, ContentScatter.chunk_for_tile(map_pos))
	if entry.is_empty():
		return base_logic
	var footprint: Rect2i = entry["footprint"]
	if not footprint.has_point(map_pos):
		return base_logic
	var cell := Landmarks._tile_for(str(entry["landmark_id"]), map_pos - footprint.position)
	var logic := Landmarks.cell_logic_for(cell, str(entry["landmark_id"]), base_logic)
	logic["landmark_instance"] = str(entry["instance_key"])
	return logic


# --- derivation (pure) -------------------------------------------------------------

static func _derive(world_seed: int, chunk: Vector2i) -> Dictionary:
	if not ContentScatter.landmark_present(world_seed, chunk):
		return {}
	var kind_index := ContentScatter.landmark_kind_index(world_seed, chunk, Landmarks.LANDMARK_IDS.size())
	var landmark_id := str(Landmarks.LANDMARK_IDS[kind_index])
	var size: Vector2i = Landmarks._SIZES[landmark_id]
	var home := ContentScatter.landmark_home_tile(world_seed, chunk)
	var noise := BiomeField.elevation_noise(world_seed)
	var anchor := _search(world_seed, noise, home, size)
	if anchor == Vector2i.MAX:
		return {} # presence rolled but no land-fit anchor inside the budget — the chunk stays empty (bounded generation)
	return {
		"landmark_id": landmark_id,
		"anchor": anchor,
		"footprint": Rect2i(anchor - size / 2, size),
		"instance_key": ContentScatter.instance_key(landmark_id, anchor),
	}


# The bounded anchor search: Chebyshev spiral from the home tile (the landmarks.anchor_for
# pattern), 7-of-9 land probes, and the scatter ring floor (the origin-core preservation —
# a spiral that wanders inward past the floor is rejected, never clamped).
static func _search(world_seed: int, noise: FastNoiseLite, home: Vector2i, size: Vector2i) -> Vector2i:
	var checked := 0
	var radius := 0
	while checked < Landmarks.ANCHOR_SEARCH_BUDGET:
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if checked >= Landmarks.ANCHOR_SEARCH_BUDGET:
					break
				if radius == 0 or maxi(absi(x), absi(y)) == radius:
					checked += 1
					var probe := home + Vector2i(x, y)
					if ContentScatter.ring_of(probe) < SCATTER_MIN_RING:
						continue
					if ContentScatter.chunk_for_tile(probe - size / 2) != ContentScatter.chunk_for_tile(probe + size / 2 - Vector2i.ONE):
						continue # footprint would straddle a chunk border (the margin keeps homes interior; the spiral may not)
					if Landmarks._fits_on_land(noise, probe, size):
						return probe
		radius += 1
	return Vector2i.MAX
