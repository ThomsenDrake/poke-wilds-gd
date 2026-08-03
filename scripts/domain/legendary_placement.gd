extends RefCounted

# Phase 7 Build 2 — legendaries (spec: docs/product-specs/world-depth.md § Legendaries).
# The frozen seven as STATIC, climate-anchored STATIONARY encounters — never a random-pool
# entry (NO legendary has any wilds_data.asm spawn line; biome_encounters.gd carries
# the matching never-encounter exclusion beside this module). PURE domain rules: the
# anchor search rides overworld_mons._mix SplitMix + a per-species salt (distinct odd
# constants, streams uncorrelated), and the biome test delegates to BiomeField (the ONE
# climate source — infinite-world slice 2 collapsed the local mirror; deterministic noise,
# the landmarks.gd land-test precedent, its header :9). NO RandomNumberGenerator / engine
# hash() / dict iteration in any roll; NO I/O, NO save access. Removal persistence
# rides session_state.legendary_removals (v4-additive, marshalled in session_payload.gd);
# this module owns ONLY the key grammar + the suppression predicate.
#
# FAITHFUL ANCHORS (.firecrawl/wiki-overworld-encounters.md): stationary legendaries
# (:224), the +3 chase-catch buff (:284), KO/catch removal + white-out leaves mons
# (:288). LOAD-BEARING FLAGGED DIVERGENCE: :224 says ORIGINAL stationary legendaries
# ARE re-battleable after a KO; the frozen contract DELIBERATELY inverts that to
# GONE-FOR-GOOD per-world (PORT DECISION — the white-out-persistence half stays
# faithful, the KO-removal half contradicts the source). Never silently "correct"
# this back to re-battleable-on-KO.

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd") # _mix SplitMix convention (same layer)
const Landmarks := preload("res://scripts/domain/landmarks.gd") # prop/cliff mirror + footprint exclusion (same layer)
const BiomeDefs := preload("res://scripts/domain/biome_defs.gd") # the affinity biomes' blocking-prop chances (same layer)
const BiomeField := preload("res://scripts/domain/biome_field.gd") # the ONE climate source (infinite-world slice 2; the local mirrors are gone)
const ContentScatter := preload("res://scripts/domain/content_scatter.gd") # the chunk rolls + lair suppression (slice 3; no cycle)
const LandmarkScatter := preload("res://scripts/domain/landmark_scatter.gd") # the scattered-footprint exclusion (slice 3; no cycle)

# --- The frozen seven (FROZEN set — spec § Legendaries) ---------------------------
# Roster identity is grounded by the catalog + the ONE wired battle track
# (music_router.gd:33 "legendary" = gsc-vs-legendary-beasts.ogg), NOT by the FAQ
# count (fresh-faq.md:156 names "seven" but not WHICH seven). Order is pinned.
const LEGENDARY_IDS := ["MEWTWO", "REGIROCK", "REGICE", "REGISTEEL", "REGIELEKI", "REGIDRAGO", "REGIGIGAS"]
# Per-legendary biome affinity (PORT DESIGN, flagged — unfalsifiable against sources:
# no scrape ties any legendary to any biome; the exec plan's "SNOW/LAVA rings" is a
# design decision). MEWTWO on LAVA = the deepest/hardest.
const AFFINITY := {
	"REGICE": "SNOW",
	"REGIELEKI": "SNOW",
	"REGIGIGAS": "SNOW",
	"REGIROCK": "LAVA",
	"REGISTEEL": "LAVA",
	"REGIDRAGO": "LAVA",
	"MEWTWO": "LAVA"
}
# Per-species derived-hash salts — distinct odd constants, uncorrelated with the
# overworld_mons salts (0x1..0x13) and SALT_LANDMARK_ANCHOR (0x23); extends the
# convention's named set (overworld_mons.gd:69-80).
const SPECIES_SALTS := {
	"MEWTWO": 0x31,
	"REGIROCK": 0x33,
	"REGICE": 0x35,
	"REGISTEEL": 0x37,
	"REGIELEKI": 0x39,
	"REGIDRAGO": 0x3B,
	"REGIGIGAS": 0x3D
}
const LEGENDARY_REACH := 256 # the anchor scan's bounded box (±256 of origin): rings are retired with the radial model (infinite-world slice 2); the box is the budget's outer bound
const LEGENDARY_LATTICE_STRIDE := 34 # score-lattice spacing; the climate fields correlate at ~150-250 tiles, so a 16x16 lattice resolves every climate region in the box
const ANCHOR_CANDIDATES := 6 # the top score regions each scan walks (the _mix pick spreads species over distinct pockets)
const LEGENDARY_ANCHOR_BUDGET := 300 # spec: bounded probe count (bounded generation; FAQ :208-210 stuck-worldgen contract) — 256 score evals + up to 6x(1+4) biome/standable probes = 286
const LEGENDARY_RING_MIN := 60 # PROGRESSION floor (re-justified in slice 2: no longer a biome-admission band — a legendary may never anchor within Manhattan 60 of origin, so early game stays safe and guardian levels (ring-fed) stay deep)
const BATTLE_KIND_LEGENDARY := "legendary" # the music seam (music_router.gd:33) a legendary entity sets on the pending seam
const NO_ANCHOR := Vector2i.MAX # the world's reach box lacks the affinity biome (the sim's no-anchor sentinel convention)


# --- Roster predicates ------------------------------------------------------------
static func is_legendary(species_id: String) -> bool:
	return SPECIES_SALTS.has(species_id)
static func affinity_for(species_id: String) -> String:
	return str(AFFINITY.get(species_id, ""))
# Manhattan distance from origin (abs(x)+abs(y)) — kept as the payload's distance
# field (encounter level scaling rides it elsewhere; it no longer gates any biome).
static func ring_of(tile: Vector2i) -> int:
	return absi(tile.x) + absi(tile.y)


# --- Removal grammar (gone-for-good per INSTANCE; spec § Persistence) -------------
# Key "<ax>,<ay>:<SPECIES>" — the LAIR/anchor tile (infinite-world slice 3 re-keyed from
# the frozen "0,0" chain tag: repeating lairs make per-instance removal meaningful — a
# KO clears THAT lair forever, siblings stay). The persistent home is
# session_state.legendary_removals (flat Array, absent -> [], NO SAVE_VERSION bump;
# save_migration normalizes legacy "0,0:SPECIES" keys to the origin anchors losslessly);
# this module never touches the save, only the grammar + the predicate.
static func removal_key(anchor: Vector2i, species_id: String) -> String:
	return "%d,%d:%s" % [anchor.x, anchor.y, species_id]
static func is_removed(removals: Array, anchor: Vector2i, species_id: String) -> bool:
	return removals.has(removal_key(anchor, species_id))


# --- The world's stationary set (stamp-time entry point; runtime owns lifetime) ---
# One entry per frozen species whose anchor resolved, suppressed by the persistent
# removal set (chain frozen origin — slice 1; anchor-rekeyed in slice 3). Entry
# shape == the legendary_encounter trace payload: {species_id, tile, biome, ring, battle_kind: "legendary"}.
# A world whose reach box lacks the affinity biome simply lacks that biome's legendaries.
static func legendaries_for_world(world_seed: int, chain: Vector2i, removals: Array = [], reach: int = -1) -> Array:
	var present: Array = []
	var taken: Array = [] # sibling tiles — CANONICAL per (seed, chain): every species' anchor joins the exclusion whether or not it is removed, so anchors never shift as removals accumulate (the save-normalized keys stay valid)
	for species_id in LEGENDARY_IDS:
		var sid := str(species_id)
		var anchor := anchor_for(world_seed, chain, sid, reach, taken)
		if anchor == NO_ANCHOR:
			continue
		taken.append(anchor)
		if is_removed(removals, anchor, sid):
			continue
		present.append({"species_id": sid, "tile": anchor, "biome": affinity_for(sid), "ring": ring_of(anchor), "battle_kind": BATTLE_KIND_LEGENDARY})
	return present


# --- Anchor (pure _mix; guided score scan; NO_ANCHOR when the biome is absent) ------
# The affinity biomes are CLIMATE blobs (BiomeField: SNOW the cold quarter, LAVA the
# rare hot+dry+volcanic joint tail), spread across the whole seamless plane — the
# radial ring walk is retired (infinite-world slice 2; the EMPIRICAL FLAG is RESOLVED:
# LAVA generates, so the LAVA four anchor instead of resolving NO_ANCHOR). A blind
# lattice cannot find a ~0.4%-measure biome within the 300 budget, so the scan is
# GUIDED: score every point of a coarse 16x16 lattice (stride LEGENDARY_LATTICE_STRIDE
# over ±LEGENDARY_REACH) by the affinity's min-threshold-margin climate score (positive
# EXACTLY inside the biome, elevation margins included — see _affinity_score), sort with
# a total (score, x, y) order,
# then walk the top ANCHOR_CANDIDATES regions from a per-species start (the _mix
# draw) testing biome + standable with up to 4 cardinal refinements each. Probe
# accounting stays inside LEGENDARY_ANCHOR_BUDGET: 256 score evals + <=30 standable
# probes. Points inside LEGENDARY_RING_MIN are skipped (the progression floor).
# NO_ANCHOR when the box has no affinity pocket or the budget exhausts — "a world
# whose reach box lacks a biome simply lacks that biome's legendaries" (SNOW always
# resolves; LAVA resolves on most seeds — the scenario pins the exact derived set
# per pinned seed, the anchor_set_pin precedent). `reach` overrides the box for the
# scenario's synthetic NO_ANCHOR witness (a tiny box resolves nothing).
static func anchor_for(world_seed: int, chain: Vector2i, species_id: String, reach: int = -1, exclude: Array = []) -> Vector2i:
	if not is_legendary(species_id):
		push_warning("LegendaryPlacement: unknown species '%s'" % species_id)
		return NO_ANCHOR
	var biome := affinity_for(species_id)
	var h := OverworldMons._mix(world_seed, chain.x, chain.y, int(SPECIES_SALTS[species_id]))
	var channels := BiomeField.make_channels(world_seed)
	var props: Array = (BiomeDefs.new().definitions()[biome] as Dictionary).get("props", [])
	var box := LEGENDARY_REACH if reach < 0 else reach
	var scored := _score_lattice(channels, biome, box)
	var candidates := mini(scored.size(), ANCHOR_CANDIDATES)
	var start := int(h % candidates)
	var checked := (scored.size() as int) # the score evals ARE the scan's first phase
	for i in range(candidates):
		if checked >= LEGENDARY_ANCHOR_BUDGET:
			break
		var probe: Vector2i = scored[(start + i) % candidates][1]
		if ring_of(probe) < LEGENDARY_RING_MIN:
			continue # the progression floor — no anchor near origin
		checked += 1
		if BiomeField.biome_from(channels, probe) == biome and not exclude.has(probe) and _standable(channels, biome, props, chain, probe, world_seed):
			return probe
		for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]: # the candidate is the pocket's best score; a small pocket or a blocked exact tile usually yields a neighbor
			if checked >= LEGENDARY_ANCHOR_BUDGET:
				break
			checked += 1
			var near: Vector2i = probe + direction
			if ring_of(near) >= LEGENDARY_RING_MIN and BiomeField.biome_from(channels, near) == biome and not exclude.has(near) and _standable(channels, biome, props, chain, near, world_seed):
				return near
	return NO_ANCHOR


# The score lattice, fully sorted (score desc, then x, then y — a TOTAL order, so the
# sort is deterministic even on float ties; Array.sort_custom is not stable).
static func _score_lattice(channels: Dictionary, biome: String, box: int) -> Array:
	var scored: Array = []
	for y in range(-box, box + 1, LEGENDARY_LATTICE_STRIDE):
		for x in range(-box, box + 1, LEGENDARY_LATTICE_STRIDE):
			var point := Vector2i(x, y)
			scored.append([_affinity_score(channels, biome, point), point])
	scored.sort_custom(func(a, b):
		if float(a[0]) != float(b[0]):
			return float(a[0]) > float(b[0])
		var pa: Vector2i = a[1]; var pb: Vector2i = b[1]
		return pa.x < pb.x or (pa.x == pb.x and pa.y < pb.y))
	return scored


# The climate score guiding the scan: the affinity's WEAKEST threshold margin (the
# min-margin) INCLUDING the elevation-band margins (inland: e > SAND_ELEVATION; not
# mountain: e < ROCK_BIOME_ELEVATION) — so the score is positive EXACTLY when the tile
# is the affinity biome (a beach/water/mountain tile with extreme (t,m,v) can no longer
# outrank a true pocket tile). Every pocket tile outranks every near-miss, and the
# pocket's most robust tile ranks first. Thresholds ride BiomeField's constants.
static func _affinity_score(channels: Dictionary, biome: String, tile: Vector2i) -> float:
	var t: float = (channels["temp"] as FastNoiseLite).get_noise_2d(tile.x, tile.y)
	var e := BiomeField.elevation_from(channels, tile)
	var inland := minf(e - BiomeField.SAND_ELEVATION, BiomeField.ROCK_BIOME_ELEVATION - e)
	match biome:
		"SNOW":
			return minf(BiomeField.SNOW_TEMP - t, inland)
		"LAVA":
			var m: float = (channels["moist"] as FastNoiseLite).get_noise_2d(tile.x, tile.y)
			var v: float = (channels["volc"] as FastNoiseLite).get_noise_2d(tile.x, tile.y)
			return minf(minf(t - BiomeField.LAVA_TEMP, minf(BiomeField.LAVA_MOIST - m, v - BiomeField.LAVA_VOLCANIC)), inland)
	push_warning("LegendaryPlacement: no affinity score for biome '%s'" % biome)
	return 0.0


# A tile the player can actually stand on in the affinity biome: the climate field
# agrees (BiomeField), no rocky cliff (the generator's elevation > 0.55 smash-blocker —
# vacuous today since SNOW/LAVA only occur below ROCK_BIOME_ELEVATION, kept as a guard
# against threshold drift), no blocking prop (snow tree / lava sheet through the
# generator's pick_prop channel), and NOT inside a landmark footprint (the frozen
# region_at seam keeps the sets disjoint).
static func _standable(channels: Dictionary, biome: String, props: Array, chain: Vector2i, tile: Vector2i, world_seed: int) -> bool:
	var e := BiomeField.elevation_from(channels, tile)
	if BiomeField.biome_from_e(channels, tile, e) != biome:
		return false
	if Landmarks.is_rock_cliff(e, true): # both affinity defs are walkable=true
		return false
	if Landmarks.region_at(world_seed, chain, tile) != "":
		return false
	var picked: Variant = Landmarks.pick_prop(tile, props, world_seed)
	return not (picked is Dictionary and bool((picked as Dictionary).get("block", false)))
# --- Repeating lairs (infinite-world slice 3; FLAGGED divergence) ---------------------
# The frozen seven own the origin reach box (byte-identical anchors); BEYOND it, lairs
# REPEAT across the plane (flagged: "one each" on an infinite plane is unfindable, and
# per-instance removal gives the gone-for-good contract real teeth). A lair exists where
# the chunk roll fires in the species' affinity biome; the anchor is a bounded spiral
# from the chunk's home tile to a standable affinity tile outside any scattered landmark
# footprint. NO_ANCHOR when absent/removed/never-fits (bounded generation, FAQ :208-210).
const LAIR_SEARCH_BUDGET := 64 # bounded probes around the home tile (the chunk is 64 wide)

static func lair_for_chunk(world_seed: int, chunk: Vector2i, species_id: String, removals: Array = []) -> Vector2i:
	if not is_legendary(species_id):
		push_warning("LegendaryPlacement: unknown species '%s'" % species_id)
		return NO_ANCHOR
	var index := LEGENDARY_IDS.find(species_id)
	var biome := affinity_for(species_id)
	if not ContentScatter.lair_present(world_seed, chunk, index, biome):
		return NO_ANCHOR
	var home := ContentScatter.lair_home_tile(world_seed, chunk, index)
	var channels := BiomeField.make_channels(world_seed)
	var props: Array = (BiomeDefs.new().definitions()[biome] as Dictionary).get("props", [])
	var footprint := Rect2i()
	var scattered := LandmarkScatter.instance_for_chunk(world_seed, chunk)
	if not scattered.is_empty():
		footprint = scattered["footprint"]
	var checked := 0
	var radius := 0
	while checked < LAIR_SEARCH_BUDGET:
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if checked >= LAIR_SEARCH_BUDGET:
					break
				if radius == 0 or maxi(absi(x), absi(y)) == radius:
					checked += 1
					var probe := home + Vector2i(x, y)
					if ContentScatter.chebyshev_of(probe) <= ContentScatter.LAIR_MIN_RING:
						continue # the lair must sit OUTSIDE the origin seven's ±256 reach box (authoritative floor)
					if footprint.size != Vector2i.ZERO and footprint.has_point(probe):
						continue
					if BiomeField.biome_from(channels, probe) == biome and _standable(channels, biome, props, Vector2i.ZERO, probe, world_seed):
						return NO_ANCHOR if is_removed(removals, probe, species_id) else probe # the lair tile IS the removal anchor
		radius += 1
	return NO_ANCHOR
