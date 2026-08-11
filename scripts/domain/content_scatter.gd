extends RefCounted

# Chunk-hash content scattering (infinite-world slice 3; spec: docs/product-specs/world-depth.md
# — the successor infinite-world.md lands in slice 5). Scatters LANDMARK instances across the
# seamless plane by 64-tile chunk hash, so the infinite world has content everywhere — the
# original's "stuff everywhere" feel (a FLAGGED modernization: the original was chained bounded
# maps; the user chose the seamless plane). The repeating legendary LAIRS and the predicate-only
# dungeon-SITE rolls are RETIRED (legendary-dungeon slice: the frozen seven move into
# warp-entered hand-authored dungeons — the dungeon slice the site rolls were measuring for).
# Every roll rides the proven overworld_mons._mix SplitMix — NO RandomNumberGenerator,
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

const CONTENT_CHUNK := 64 # tiles per chunk edge; an 8x8 block of overworld cells (CELL_SIZE 8)
# Salts continue the named odd-constant convention (overworld 0x1..0x13, WORLD 0x21,
# LANDMARK_ANCHOR 0x23, legendary species 0x31..0x3D — all < 0x41). This block allocates
# DISTINCT landmark streams (0x41/43/45 — stream independence is load-bearing determinism,
# overworld_mons.gd:14-15); the retired lair (0x51/0x53) and dungeon-site (0x47/49) salts stay
# RESERVED so a future family never collides with a pinned stream.
const SALT_LANDMARK_CHUNK := 0x41
const SALT_LANDMARK_KIND := 0x43
const SALT_LANDMARK_HOME := 0x45

# Density (FLAGGED invention; per-mille of chunks). 12‰ landmarks ≈ one per ~83 chunks
# (~every 5-6 chunk widths of travel).
const LANDMARK_PRESENT_PER_MILLE := 12

# Suppression radius (the origin-core preservation): no scattered landmark whose chunk center
# lies within Manhattan 96 of origin (the three canonical landmarks own the core).
const ORIGIN_CORE_RADIUS := 96
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
