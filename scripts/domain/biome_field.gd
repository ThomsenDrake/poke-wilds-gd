extends RefCounted

# Climate-field biome model (infinite-world slice 2; spec: docs/product-specs/world-depth.md
# — the successor infinite-world.md lands in slice 5). The ONE shared source for "what biome
# is this tile": it collapses the THREE verbatim mirrors the radial model was pasted into
# (world_generator._pick_biome + _ring_candidates, legendary_placement._biome_from +
# _ring_candidates, landmarks._elevation_noise), so mirror drift is impossible by
# construction. The radial model assigned land biomes by Manhattan-distance rings
# (candidates at 10/28/60); the climate model derives them from THREE continuous fields —
# temperature / moisture / volcanism — so EVERY biome has nonzero measure anywhere on the
# seamless plane. That fixes the radial quantization-tail gap: LAVA was candidate index 8
# of 9 at ring >= 60 and the biome noise never reached region >= 0.889 (the legendary
# EMPIRICAL FLAG) — now LAVA is the joint tail of three independent fields and generates.
# PURE: FastNoiseLite is (seed,x,y)-pure; NO RandomNumberGenerator, NO I/O (the
# world_depth_rng_issues ban covers scripts/domain/**). Every threshold below is a FLAGGED
# invention (the sources document no biome model at this fidelity), calibrated against the
# world-gen audit's biome-distribution measurement and tunable by real playtesters.

# --- The climate table (FLAGGED inventions; priority-ordered — the order is load-bearing) --
const WATER_ELEVATION := -0.30 # elevation gates UNCHANGED from the radial model: coastlines are model-invariant
const SAND_ELEVATION := -0.12 # the beach band, UNCHANGED (the slice-4 beach spawn + the landmark land test ride it)
const ROCK_BIOME_ELEVATION := 0.45 # mountains from elevation (ROCK was a ring >= 28 candidate); e > 0.55 still gets the smash cliff prop
const SNOW_TEMP := -0.35
const LAVA_TEMP := 0.40 # calibrated against the measured field range (2-octave FastNoiseLite peaks p99 ~0.62-0.68; this joint tail measures ~0.02-0.9% of tiles per seed across the audit's 9 windows — present in 8 of 9; a cold-climate window legitimately lacks LAVA, so presence is enforced ONLY cross-seed (LAVA_WINDOWS_MIN), never per-seed)
const LAVA_MOIST := -0.15
const LAVA_VOLCANIC := 0.40
const DESERT_TEMP := 0.15
const DRY_MOIST := -0.20
const ARID_MOIST := 0.05
const WET_MOIST := 0.40
const FOREST_MOIST := 0.10
const COOL_TEMP := -0.10

const KNOWN_BIOMES: Array = ["WATER", "SAND", "PLAINS", "GRASSLAND", "FOREST", "SAVANNA", "DESERT", "SWAMP", "ROCK", "SNOW", "LAVA"] # the closed 11-biome set (biome_defs.gd's keys; the audit's distribution check iterates this)


# The ONE channel factory — every frequency/salt lives here and nowhere else:
#   elevation  (seed,         0.010, 4 oct, gain 0.45) — UNCHANGED radial channel (WATER/SAND/ROCK gates; landmark land test)
#   temperature(seed + 7919,  0.006, 2 oct, gain 0.50) — NEW hot/cold axis
#   moisture   (seed + 104729,0.007, 2 oct, gain 0.50) — NEW wet/dry axis
#   volcanism  (seed + 4242,  0.004, 2 oct, gain 0.50) — REUSES the retired radial biome channel as the rare-volcanic mask
# Low frequencies -> broad regions, not salt-and-pepper. Salts continue the additive-salt
# convention (+9931 tall_grass, +4242 biome) with distinct large offsets.
static func make_channels(seed_value: int) -> Dictionary:
	var temperature := FastNoiseLite.new()
	temperature.seed = seed_value + 7919
	temperature.frequency = 0.006
	temperature.fractal_octaves = 2
	temperature.fractal_lacunarity = 2.0
	temperature.fractal_gain = 0.50
	var moisture := FastNoiseLite.new()
	moisture.seed = seed_value + 104729
	moisture.frequency = 0.007
	moisture.fractal_octaves = 2
	moisture.fractal_lacunarity = 2.0
	moisture.fractal_gain = 0.50
	var volcanism := FastNoiseLite.new()
	volcanism.seed = seed_value + 4242
	volcanism.frequency = 0.004
	volcanism.fractal_octaves = 2
	volcanism.fractal_lacunarity = 2.0
	volcanism.fractal_gain = 0.50
	return {"elev": elevation_noise(seed_value), "temp": temperature, "moist": moisture, "volc": volcanism}


# The elevation channel, single-sourced (landmarks._fits_on_land + is_rock_cliff ride it;
# the :281-288 / :189-196 mirrors collapse here). UNCHANGED radial parameters, so landmark
# anchors and coastlines are byte-identical across the model swap.
static func elevation_noise(seed_value: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.010
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.45
	return noise


static func elevation_from(channels: Dictionary, tile: Vector2i) -> float:
	return (channels["elev"] as FastNoiseLite).get_noise_2d(tile.x, tile.y)


# Hot path with a precomputed elevation (the generator needs e for the cliff gate anyway —
# 4 noise evals per tile, never 5).
static func biome_from_e(channels: Dictionary, tile: Vector2i, e: float) -> String:
	if e < WATER_ELEVATION:
		return "WATER"
	if e < SAND_ELEVATION:
		return "SAND"
	if e >= ROCK_BIOME_ELEVATION:
		return "ROCK"
	var t: float = (channels["temp"] as FastNoiseLite).get_noise_2d(tile.x, tile.y)
	if t < SNOW_TEMP:
		return "SNOW"
	var m: float = (channels["moist"] as FastNoiseLite).get_noise_2d(tile.x, tile.y)
	# LAVA = RARE hot+dry+volcanic pockets: the joint tail of three independent fields —
	# nonzero measure everywhere, never a quantization accident (the header's fix).
	if t > LAVA_TEMP and m < LAVA_MOIST and (channels["volc"] as FastNoiseLite).get_noise_2d(tile.x, tile.y) > LAVA_VOLCANIC:
		return "LAVA"
	if t >= DESERT_TEMP and m < DRY_MOIST:
		return "DESERT"
	if t >= DESERT_TEMP and m < ARID_MOIST:
		return "SAVANNA"
	if m >= WET_MOIST:
		return "SWAMP"
	if m >= FOREST_MOIST and t >= COOL_TEMP:
		return "FOREST"
	if m >= DRY_MOIST and t >= COOL_TEMP:
		return "GRASSLAND"
	return "PLAINS" # the cool/dry fallback steppe


# Rare-path form (legendary anchor scans / audits build channels once per search, not per tile).
static func biome_from(channels: Dictionary, tile: Vector2i) -> String:
	return biome_from_e(channels, tile, elevation_from(channels, tile))


# Convenience for tests/audit spot checks (builds channels per call — never the hot path).
static func biome_at(seed_value: int, tile: Vector2i) -> String:
	return biome_from(make_channels(seed_value), tile)
