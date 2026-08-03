extends RefCounted

# Chunk-hash content scattering (infinite-world slice 3; spec: docs/product-specs/world-depth.md
# — the successor infinite-world.md lands in slice 5). Scatters LANDMARK instances, repeating
# LEGENDARY LAIRS, and dungeon SITE predicates across the seamless plane by 64-tile chunk hash,
# so the infinite world has content everywhere — the original's "stuff everywhere" feel (a
# FLAGGED modernization: the original was chained bounded maps; the user chose the seamless
# plane). Every roll rides the proven overworld_mons._mix SplitMix — NO RandomNumberGenerator,
# NO engine hash(), NO dict iteration, NO I/O (the scripts/domain/** ban). Every enumeration is
# WINDOW-bounded by construction (chunks around a center, never the whole plane).
#
# ORIGIN-CORE PRESERVATION (the slice's pinning discipline): the three origin landmark anchors
# and the seven origin legendary anchors (the ±256 reach box) stay byte-identical — scattering
# lives BEYOND the origin core, so the calibrated origin region (spawn framing, the visual
# baselines, the landmark_flow / legendary_spawn scenario pins) does not move. The density
# constants are FLAGGED inventions (no source documents densities), calibrated against the
# world-gen audit's content-density measurement and tunable by real playtesters.

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd") # _mix SplitMix + _floor_div (same layer)
const BiomeField := preload("res://scripts/domain/biome_field.gd") # the ONE climate source (lair affinity tests)

const CONTENT_CHUNK := 64 # tiles per chunk edge; an 8x8 block of overworld cells (CELL_SIZE 8)
# Salts continue the named odd-constant convention (overworld 0x1..0x13, WORLD 0x21,
# LANDMARK_ANCHOR 0x23, legendary species 0x31..0x3D — all < 0x41). This block allocates
# DISTINCT streams: landmark (0x41/43/45), dungeon (0x47/49), then the lair presence/home
# ranges stride LAIR_SPECIES_STRIDE apart so NO presence stream collides with a sibling home
# stream or a dungeon salt (a stride-2 layout folded presence[i] onto home[i-1] and onto the
# dungeon salts — stream independence is load-bearing determinism, overworld_mons.gd:14-15).
const SALT_LANDMARK_CHUNK := 0x41
const SALT_LANDMARK_KIND := 0x43
const SALT_LANDMARK_HOME := 0x45
const SALT_DUNGEON_SITE := 0x47
const SALT_DUNGEON_HOME := 0x49
const SALT_LAIR_CHUNK := 0x51 # lair presence base; + species_index * LAIR_SPECIES_STRIDE
const SALT_LAIR_HOME := 0x53 # lair home base; + species_index * LAIR_SPECIES_STRIDE
const LAIR_SPECIES_STRIDE := 0x10 # keeps all 14 lair streams + the 5 landmark/dungeon salts pairwise distinct

# Densities (FLAGGED inventions; per-mille of chunks). 12‰ landmarks ≈ one per ~83 chunks
# (~every 5-6 chunk widths of travel); 3‰ lairs per species ≈ one per ~333 chunks (rare
# deep-biome landmarks, not carpets); 20‰ dungeon sites ≈ one per 50 chunks.
const LANDMARK_PRESENT_PER_MILLE := 12
const LAIR_PRESENT_PER_MILLE := 3
const DUNGEON_SITE_PER_MILLE := 20

# Suppression radii (the origin-core preservation): no scattered landmark whose chunk center
# lies within Manhattan 96 of origin (the three canonical landmarks own the core); no repeat
# lair TILE within Chebyshev 256 of origin (the origin seven's ±256 reach box owns the inner
# plane — the per-probe floor in lair_for_chunk is the authoritative gate, the chunk-center
# test below is a conservative early-out).
const ORIGIN_CORE_RADIUS := 96
const LAIR_MIN_RING := 256
# The sub-anchor search stays inside the chunk by construction: an anchor margin of 8 keeps
# even the widest footprint (15x11, half-extent 7x5) from straddling a chunk border, so
# scattered siblings are disjoint ACROSS chunks structurally (no cross-chunk _disjoint pass).
const ANCHOR_MARGIN := 8


static func chunk_for_tile(tile: Vector2i) -> Vector2i:
	return Vector2i(OverworldMons._floor_div(tile.x, CONTENT_CHUNK), OverworldMons._floor_div(tile.y, CONTENT_CHUNK))


static func chunk_origin(chunk: Vector2i) -> Vector2i:
	return chunk * CONTENT_CHUNK


static func chunk_center(chunk: Vector2i) -> Vector2i:
	return chunk * CONTENT_CHUNK + Vector2i(CONTENT_CHUNK / 2, CONTENT_CHUNK / 2)


static func ring_of(tile: Vector2i) -> int:
	return absi(tile.x) + absi(tile.y)


# Chebyshev distance — the origin seven's reach box is a ±LEGENDARY_REACH CHEBYSHEV square
# (corners at Manhattan ring 2*REACH), so lair suppression must test THIS metric, not the
# Manhattan ring (a Manhattan-256 gate would still admit lairs inside the box's corners).
static func chebyshev_of(tile: Vector2i) -> int:
	return maxi(absi(tile.x), absi(tile.y))


# The 3x3 chunk window whose scattered footprints can touch `tile` (footprints stay inside
# their own chunk by the ANCHOR_MARGIN rule, so the tile's own chunk suffices today — the
# window form keeps the contract explicit if the margin rule ever relaxes).
static func chunks_for_tile(tile: Vector2i) -> Array:
	return [chunk_for_tile(tile)]


# The chunks intersecting a square window around `center_tile` (bounded enumeration for the
# runtime/audit: never enumerate the plane).
static func chunks_in_window(center_tile: Vector2i, half_extent_tiles: int) -> Array:
	var lo := chunk_for_tile(center_tile - Vector2i(half_extent_tiles, half_extent_tiles))
	var hi := chunk_for_tile(center_tile + Vector2i(half_extent_tiles, half_extent_tiles))
	var chunks: Array = []
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			chunks.append(Vector2i(cx, cy))
	return chunks


# --- Landmark scattering ----------------------------------------------------------

# A chunk scatters a landmark iff its center lies beyond the origin core AND the presence
# roll lands. Deterministic per (seed, chunk).
static func landmark_present(world_seed: int, chunk: Vector2i) -> bool:
	if ring_of(chunk_center(chunk)) <= ORIGIN_CORE_RADIUS:
		return false
	return OverworldMons._mix(world_seed, chunk.x, chunk.y, SALT_LANDMARK_CHUNK) % 1000 < LANDMARK_PRESENT_PER_MILLE


# The landmark KIND for a present chunk — LANDMARK_IDS order is pinned, so the kind is a
# pure roll. Kept as an index (not the id string) so this module never imports landmarks.gd.
static func landmark_kind_index(world_seed: int, chunk: Vector2i, kind_count: int) -> int:
	return int(OverworldMons._mix(world_seed, chunk.x, chunk.y, SALT_LANDMARK_KIND) % kind_count)


# The deterministic sub-anchor START tile inside the chunk interior (margin-kept); the
# landmark module's bounded land/disjoint search refines it into the real anchor.
static func landmark_home_tile(world_seed: int, chunk: Vector2i) -> Vector2i:
	var h := OverworldMons._mix(world_seed, chunk.x, chunk.y, SALT_LANDMARK_HOME)
	var interior := CONTENT_CHUNK - 2 * ANCHOR_MARGIN # 48
	var origin := chunk_origin(chunk)
	return origin + Vector2i(ANCHOR_MARGIN + int(h % interior), ANCHOR_MARGIN + int((h >> 16) % interior))


# --- Legendary lairs (REPEATING — flagged divergence, see header) -------------------

# A chunk hosts a lair for the species iff: beyond the lair suppression ring, the chunk
# center's climate biome is the species' affinity (LAIRS LIVE IN THEIR BIOME — the whole
# point of the climate field), and the per-species presence roll lands.
static func lair_present(world_seed: int, chunk: Vector2i, species_index: int, affinity_biome: String) -> bool:
	var center := chunk_center(chunk)
	if chebyshev_of(center) + CONTENT_CHUNK <= LAIR_MIN_RING:
		return false # the whole chunk sits inside the exclusion zone (conservative early-out)
	if BiomeField.biome_at(world_seed, center) != affinity_biome:
		return false
	return OverworldMons._mix(world_seed, chunk.x, chunk.y, SALT_LAIR_CHUNK + species_index * LAIR_SPECIES_STRIDE) % 1000 < LAIR_PRESENT_PER_MILLE


# The deterministic lair search START tile inside the chunk (margin-kept like landmarks).
static func lair_home_tile(world_seed: int, chunk: Vector2i, species_index: int) -> Vector2i:
	var h := OverworldMons._mix(world_seed, chunk.x, chunk.y, SALT_LAIR_HOME + species_index * LAIR_SPECIES_STRIDE)
	var interior := CONTENT_CHUNK - 2 * ANCHOR_MARGIN
	var origin := chunk_origin(chunk)
	return origin + Vector2i(ANCHOR_MARGIN + int(h % interior), ANCHOR_MARGIN + int((h >> 16) % interior))


# --- Dungeon SITES (predicate-only — NO dungeons are built; the audit measures) ------

static func dungeon_site_present(world_seed: int, chunk: Vector2i) -> bool:
	return OverworldMons._mix(world_seed, chunk.x, chunk.y, SALT_DUNGEON_SITE) % 1000 < DUNGEON_SITE_PER_MILLE


static func dungeon_site_center(world_seed: int, chunk: Vector2i) -> Vector2i:
	var h := OverworldMons._mix(world_seed, chunk.x, chunk.y, SALT_DUNGEON_HOME)
	var interior := CONTENT_CHUNK - 2 * ANCHOR_MARGIN
	var origin := chunk_origin(chunk)
	return origin + Vector2i(ANCHOR_MARGIN + int(h % interior), ANCHOR_MARGIN + int((h >> 16) % interior))


# --- Instance keying ---------------------------------------------------------------

# The per-instance landmark state key: "<landmark_id>@<anchor.x>,<anchor.y>". The anchor is
# a pure function of (seed, chunk), so the key is stable across saves/reloads.
static func instance_key(landmark_id: String, anchor: Vector2i) -> String:
	return "%s@%d,%d" % [landmark_id, anchor.x, anchor.y]


static func parse_instance_key(key: String) -> Dictionary: # {"id": ..., "anchor": Vector2i} or {} on garbage
	var parts := key.split("@")
	if parts.size() != 2:
		return {}
	var coords := parts[1].split(",")
	if coords.size() != 2 or not coords[0].is_valid_int() or not coords[1].is_valid_int():
		return {}
	return {"id": str(parts[0]), "anchor": Vector2i(coords[0].to_int(), coords[1].to_int())}
