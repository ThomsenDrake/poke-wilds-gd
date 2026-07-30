extends RefCounted

# Phase 7 Build 2 — legendaries (spec: docs/product-specs/world-depth.md § Legendaries).
# The frozen seven as STATIC, ring-gated STATIONARY encounters — never a random-pool
# entry (NO legendary has any wilds_data.asm spawn line; biome_encounters.gd carries
# the matching never-encounter exclusion beside this module). PURE domain rules: the
# anchor search rides overworld_mons._mix SplitMix + a per-species salt (distinct odd
# constants, streams uncorrelated), and the biome test mirrors world_generator's two
# FastNoiseLite channels (elevation :33-39, biome :50-55 — deterministic noise, the
# landmarks.gd land-test precedent, its header :9). NO RandomNumberGenerator / engine
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
const LEGENDARY_RING_MIN := 60 # ring-≥60 band: SNOW/LAVA first enter _ring_candidates here (world_generator.gd:292-293)
const LEGENDARY_ANCHOR_BUDGET := 300 # spec: bounded probe count (bounded generation; FAQ :208-210 stuck-worldgen contract)
const PROBES_PER_RING := 4 # one quadrant sample per diamond face per ring (budget/4 = 75 rings walked outward from ring 60)
const BATTLE_KIND_LEGENDARY := "legendary" # the music seam (music_router.gd:33) a legendary entity sets on the pending seam
const NO_ANCHOR := Vector2i.MAX # the world's ring band lacks the affinity biome (the sim's no-anchor sentinel convention)


# --- Roster predicates ------------------------------------------------------------
static func is_legendary(species_id: String) -> bool:
	return SPECIES_SALTS.has(species_id)
static func affinity_for(species_id: String) -> String:
	return str(AFFINITY.get(species_id, ""))
# Manhattan distance from the ACTIVE world's local origin — the same ring measure
# world_generator's bands use (abs(x)+abs(y), :280); each chained world re-derives
# from its OWN (0,0) (spec § World chaining).
static func ring_of(tile: Vector2i) -> int:
	return absi(tile.x) + absi(tile.y)


# --- Removal grammar (gone-for-good per-world; spec § Persistence) ----------------
# Key "<cx>,<cy>:<SPECIES>" — the bare "<cx>,<cy>" chain tag shares ONE grammar with
# SaveMigration.world_id_for (Build 3); NO "w" prefix anywhere. The persistent home
# is session_state.legendary_removals (flat Array, absent -> [], NO SAVE_VERSION
# bump); this module never touches the save, only the grammar + the predicate.
static func removal_key(chain: Vector2i, species_id: String) -> String:
	return "%d,%d:%s" % [chain.x, chain.y, species_id]
static func is_removed(removals: Array, chain: Vector2i, species_id: String) -> bool:
	return removals.has(removal_key(chain, species_id))


# --- The world's stationary set (stamp-time entry point; runtime owns lifetime) ---
# One entry per frozen species whose anchor resolved, suppressed by the persistent
# removal set (chain-scoped — works for origin AND chained worlds without v5). Entry
# shape == the legendary_encounter trace payload minus `chain` (the stamper threads
# the ACTIVE chain): {species_id, tile, biome, ring, battle_kind: "legendary"}.
# A world whose ring band lacks a biome simply lacks that biome's legendaries.
static func legendaries_for_world(world_seed: int, chain: Vector2i, removals: Array = []) -> Array:
	var present: Array = []
	for species_id in LEGENDARY_IDS:
		var sid := str(species_id)
		if is_removed(removals, chain, sid):
			continue
		var anchor := anchor_for(world_seed, chain, sid)
		if anchor == NO_ANCHOR:
			continue
		present.append({"species_id": sid, "tile": anchor, "biome": affinity_for(sid), "ring": ring_of(anchor), "battle_kind": BATTLE_KIND_LEGENDARY})
	return present


# --- Anchor (pure _mix; bounded search; NO_ANCHOR when the biome is absent) -------
# The affinity biomes are LOW-FREQUENCY noise picks (world_generator's 0.004 biome
# channel), so they form a handful of huge blobs, NOT a uniform band: the search
# walks OUTWARD from ring LEGENDARY_RING_MIN (four species-rotated quadrant probes
# per ring, 75 rings to 134 within the budget), never a tight spiral. Each probe is
# a pure function of the single _mix draw; NO_ANCHOR when the budget exhausts —
# "a world whose ring band lacks a biome simply lacks that biome's legendaries".
# EMPIRICAL FLAG (frozen-contract tension, surfaced not silently resolved): the
# contract's "origin worlds always have SNOW+LAVA at ring ≥60" holds for the
# CANDIDATE list (world_generator._ring_candidates) but NOT the generated tiles —
# the biome noise never reaches the LAVA window (region ≥ 8/9 ≈ 0.889 — candidate
# index 8 of 9 at ring ≥60, the pick is clampi(int(region*9),0,8)), so measured
# origin worlds (every pinned world-depth seed included) carry ZERO LAVA tiles out
# to ring 400 while SNOW is common (first ring seed-dependent: 60/96/133/160 across
# the pinned seeds). The LAVA-affinity four therefore resolve NO_ANCHOR on origin
# worlds — contract-legal ("the world lacks the biome"); the scenario PINS three-of-
# seven + the NO_ANCHOR negative proof (gate-enforced via lava_absent), and a re-pin
# to generated biomes is a tracked spec-level call. The SNOW three anchor from ring 60.
# EFFECTIVE REACHABILITY BOUND: the budget walks rings 60..134 (300 probes ÷ 4 per
# ring), so a biome whose first standable blob sits beyond ring 134 also yields
# NO_ANCHOR in that world (the SNOW first-ring 160 seed is such a case) — the frozen
# clause bounds the search, never an unbounded loop.
static func anchor_for(world_seed: int, chain: Vector2i, species_id: String) -> Vector2i:
	if not is_legendary(species_id):
		push_warning("LegendaryPlacement: unknown species '%s'" % species_id)
		return NO_ANCHOR
	var biome := affinity_for(species_id)
	var h := OverworldMons._mix(world_seed, chain.x, chain.y, int(SPECIES_SALTS[species_id]))
	var elevation := _elevation_noise(world_seed)
	var biome_noise := _biome_noise(world_seed)
	var props: Array = (BiomeDefs.new().definitions()[biome] as Dictionary).get("props", [])
	for i in range(LEGENDARY_ANCHOR_BUDGET):
		var ring := LEGENDARY_RING_MIN + i / PROBES_PER_RING
		# Quadrant i%4, rotated by the species hash within the quadrant (s < 4*ring by
		# construction, so _ring_tile's face/along stay in range): every ring sampled
		# once per diamond face, the rotation keeping distinct species far apart.
		var probe := _ring_tile(ring, i % PROBES_PER_RING, int(h % ring))
		if ring_of(probe) >= LEGENDARY_RING_MIN and _standable(elevation, biome_noise, biome, props, chain, probe, world_seed):
			return probe
	return NO_ANCHOR


# A tile the player can actually stand on in the affinity biome: the biome mirror
# agrees (SNOW/LAVA never occur below ring 60), no rocky cliff (the generator's
# elevation > 0.55 smash-blocker), no blocking prop (snow tree / lava sheet through
# the generator's pick_prop channel), and NOT inside a landmark footprint (footprints
# sit at rings 34/40/48 + half-size — normally well under 60, but an anchor's bounded
# wander could push one close; the frozen region_at seam keeps the sets disjoint).
static func _standable(elevation: FastNoiseLite, biome_noise: FastNoiseLite, biome: String, props: Array, chain: Vector2i, tile: Vector2i, world_seed: int) -> bool:
	var e := elevation.get_noise_2d(tile.x, tile.y)
	if _biome_from(e, biome_noise, tile) != biome:
		return false
	if Landmarks.is_rock_cliff(e, true): # both affinity defs are walkable=true
		return false
	if Landmarks.region_at(world_seed, chain, tile) != "":
		return false
	var picked: Variant = Landmarks.pick_prop(tile, props, world_seed)
	return not (picked is Dictionary and bool((picked as Dictionary).get("block", false)))


# --- Generator mirrors (verbatim channels; deterministic noise, NOT I/O) ----------
# world_generator._pick_biome (:275-283) over the two mirrored channels below, so
# the domain biome test agrees with get_tile_logic tile-for-tile (landmark logic
# keeps the HOST biome, so the resolver never disagrees either).
static func _biome_from(elevation: float, biome_noise: FastNoiseLite, tile: Vector2i) -> String:
	if elevation < -0.30:
		return "WATER"
	if elevation < -0.12:
		return "SAND"
	var candidates := _ring_candidates(ring_of(tile))
	var region := (biome_noise.get_noise_2d(tile.x, tile.y) + 1.0) * 0.5
	var index := clampi(int(region * float(candidates.size())), 0, candidates.size() - 1)
	return str(candidates[index])
# world_generator._ring_candidates (:286-294): SNOW/LAVA join at distance ≥ 60.
static func _ring_candidates(distance: int) -> Array:
	var candidates: Array = ["PLAINS", "GRASSLAND"]
	if distance >= 10:
		candidates.append_array(["FOREST", "SAVANNA"])
	if distance >= 28:
		candidates.append_array(["DESERT", "SWAMP", "ROCK"])
	if distance >= 60:
		candidates.append_array(["SNOW", "LAVA"])
	return candidates
# Mirror of world_generator's elevation channel (:33-39; the landmarks.gd :281-288 lift).
static func _elevation_noise(world_seed: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = world_seed
	noise.frequency = 0.010
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.45
	return noise
# Mirror of world_generator's biome channel (:50-55).
static func _biome_noise(world_seed: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = world_seed + 4242
	noise.frequency = 0.004
	noise.fractal_octaves = 2
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.50
	return noise
# Manhattan-ring tile (mirror of landmarks._ring_tile :272-280): face 0-3, along 0..ring.
static func _ring_tile(ring: int, face: int, along: int) -> Vector2i:
	match face:
		0:
			return Vector2i(ring - along, along)
		1:
			return Vector2i(-along, ring - along)
		2:
			return Vector2i(-(ring - along), -along)
	return Vector2i(along, -(ring - along))
