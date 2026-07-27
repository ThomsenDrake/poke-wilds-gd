extends Node

# Phase 4 field-move checks, group C — DIG stone acquisition (Phase 5; spec:
# docs/product-specs/harvest-and-mutation.md). Companion to field_moves_flow_scenario;
# group A (flash/teleport/ride/fly) lives in field_moves_checks.gd, group B (repel/
# power/charm+attack) in field_moves_ground_checks.gd. The all-field-moves party
# (FieldMovesParty; RHYPERIOR knows DIG) digs through the public harvest_tile seam:
#
#   (1) BEACH (SAND) — the FAITHFUL pool (fresh-beach.md intro + "## Dig Items":
#       Big Pearl, Water Stone, Clear Glass, Revive — the resolver DIG_BONUS_POOLS
#       ["SAND"] membership AND order). The case HUNTS water_stone: each candidate
#       tile is PREDICTED through the resolver (bonus_for is a pure function of the
#       step counter + tile — NO rng), so the dig happens only when the draw lands
#       on the documented stone, and the assert pins item_id exactly + the full
#       dig_item_found payload.
#   (2) DIVERGENT biome (the first-found of GRASSLAND/FOREST/SAVANNA/DESERT/SWAMP) —
#       pool membership asserted against the SHIPPED table (DIG_BONUS_POOLS read
#       live — a second literal list never exists). The pool CONTENT is a flagged
#       port divergence (the scrapes document NO non-Beach stone source); the assert
#       pins the shipped table, never the wiki.
#   (3) PLAINS negative control — deliberately POOL-LESS (documented dry_soil-only):
#       the dig yields the base material, emits NO dig_item_found trace, and leaves
#       all ten stone bags untouched (keeps the harvest_flow PLAINS dig byte-identical).
#
# Determinism: NO _rng consumer (the harvest seam is step-counter pure; game_runtime's
# setup seam holds). A prediction miss shifts the draw with note_player_step — that
# step also ticks breeding, so a precondition witness (_rng_free_world) asserts no
# penned mons and no party eggs, keeping the breeding tick rng-free; every dig that
# lands was predicted first, so double runs are byte-identical. The stone id set is
# STONE_ITEM_IDS (stone_evolution_runtime.gd, the single source); the pool contract
# witness opens the check.

const HarvestResolver := preload("res://scripts/runtime/harvest_resolver.gd")
const StoneEvolutionRuntime := preload("res://scripts/runtime/stone_evolution_runtime.gd")

const BEACH_BIOME := "SAND"
const BEACH_STONE := "water_stone" # the Beach pool's documented stone (fresh-beach.md)
const DIVERGENT_BIOMES := ["GRASSLAND", "FOREST", "SAVANNA", "DESERT", "SWAMP"] # probe order; first-found runs
const SCAN_RADIUS := 300 # probed: every pooled biome abounds within this ring of the spawn
const SCAN_STRIDE := 6
const CANDIDATES := 24
const ROUNDS := 32 # prediction-miss step shifts before giving up (deterministic per seed)

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []


func setup(ctx: Dictionary, runner, failures: Array) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures


# The acquisition proof: contract witness, Beach (faithful), one divergent pool,
# PLAINS control. Runs LAST in the scenario plan (its step shifts are downstream
# of every other check; teardown re-pins the clock).
func check_dig_acquisition() -> void:
	_ensure(HarvestResolver.stone_pool_contract_clean(), "dig: DIG_BONUS_POOLS breaks the stone contract (hard_stone / log / misspelled id / an id outside STONE_ITEM_IDS)")
	_ensure(_rng_free_world(), "dig: the hunt needs an rng-free world (no penned mons, no party eggs) — note_player_step's breeding tick would otherwise consume the shared encounter stream, a coupling double-run byte-identity cannot catch")
	if not _failures.is_empty():
		return
	_pool_case(BEACH_BIOME, BEACH_STONE, "beach")
	var divergent := ""
	for biome in DIVERGENT_BIOMES:
		if not _probe_dig_tiles(str(biome), SCAN_RADIUS).is_empty():
			divergent = str(biome)
			break
	if divergent.is_empty():
		_failures.append("dig: no divergent-pool biome (%s) holds a dig tile within %d rings" % [str(DIVERGENT_BIOMES), SCAN_RADIUS])
	else:
		_pool_case(divergent, "", "divergent(%s)" % divergent)
	_plains_control()


# Digs the first candidate whose PREDICTED bonus matches want_id ("" = any pool
# member), then asserts the end-to-end grant: base yield untouched, bonus bag +1,
# pool membership, and the dig_item_found payload (tile [x, y] / item_id / biome).
func _pool_case(biome: String, want_id: String, label: String) -> void:
	var candidates := _probe_dig_tiles(biome, SCAN_RADIUS)
	if candidates.is_empty():
		_failures.append("%s: no %s dig tile within %d rings" % [label, biome, SCAN_RADIUS])
		return
	var runtime = _runtime()
	var pool: Array = HarvestResolver.DIG_BONUS_POOLS.get(biome, []) as Array
	for _round in range(ROUNDS):
		for candidate in candidates:
			var tile: Vector2i = candidate["tile"]
			var predicted := HarvestResolver.bonus_for("dig", candidate["logic"], tile, int(runtime.session.total_steps))
			if predicted.is_empty() or (not want_id.is_empty() and predicted != want_id):
				continue # a miss draws nothing: the tile stays fresh, the bag untouched
			var base_id := HarvestResolver.yield_for("dig", candidate["logic"])
			var base_before: int = runtime.get_item_count(base_id)
			var bonus_before: int = runtime.get_item_count(predicted)
			var cursor: int = _runner.trace_log_line_count()
			var result: Dictionary = runtime.harvest_tile(tile)
			_ensure(bool(result.get("ok", false)) and str(result.get("yield_item", "")) == base_id, "%s: harvest refused or wrong base yield (%s)" % [label, str(result)])
			_ensure(runtime.get_item_count(base_id) == base_before + 1, "%s: the base %s grant was not exactly one" % [label, base_id])
			_ensure(runtime.get_item_count(predicted) == bonus_before + 1, "%s: the predicted bonus %s was not granted" % [label, predicted])
			_ensure(pool.has(predicted), "%s: bonus %s fell outside the shipped %s pool %s" % [label, predicted, biome, str(pool)])
			_ensure(_runner.trace_log_has_since("dig_item_found", cursor, {"tile": [tile.x, tile.y], "item_id": predicted, "biome": biome}), "%s: no dig_item_found trace for %s at %s" % [label, predicted, str(tile)])
			return
		runtime.note_player_step() # shift the step-counter draw (rng-free: _rng_free_world witnessed at entry)
	_failures.append("%s: no %s bonus draw landed within %d prediction rounds" % [label, "water_stone" if not want_id.is_empty() else "pool", ROUNDS])


# PLAINS holds NO pool (documented dry_soil-only): the dig yields the base material
# and leaves every stone bag + the dig_item_found stream untouched.
func _plains_control() -> void:
	var candidates := _probe_dig_tiles("PLAINS", 60) # the spawn island (harvest_flow finds one within 40)
	if candidates.is_empty():
		_failures.append("control: no PLAINS dig tile within 60 rings")
		return
	var runtime = _runtime()
	var tile: Vector2i = candidates[0]["tile"]
	var stones_before := {}
	for stone_id in StoneEvolutionRuntime.STONE_ITEM_IDS.keys():
		stones_before[stone_id] = runtime.get_item_count(str(stone_id))
	var soil_before: int = runtime.get_item_count("dry_soil")
	var cursor: int = _runner.trace_log_line_count()
	var result: Dictionary = runtime.harvest_tile(tile)
	_ensure(bool(result.get("ok", false)) and str(result.get("yield_item", "")) == "dry_soil", "control: PLAINS dig refused or yielded wrong (%s)" % str(result))
	_ensure(runtime.get_item_count("dry_soil") == soil_before + 1, "control: PLAINS dig did not grant exactly one dry_soil")
	_ensure(not _runner.trace_log_has_since("dig_item_found", cursor), "control: a PLAINS dig emitted a bonus find (PLAINS has no pool)")
	for stone_id in StoneEvolutionRuntime.STONE_ITEM_IDS.keys():
		_ensure(runtime.get_item_count(str(stone_id)) == int(stones_before[stone_id]), "control: PLAINS dig moved the %s bag" % str(stone_id))


# Fresh dig tiles of one biome, stride-sampled ring outward from the player (the
# world is procedural: get_tile_logic needs no sync window). Deterministic order.
func _probe_dig_tiles(biome: String, radius: int) -> Array:
	var center: Vector2i = _runtime().session.player_tile
	var found: Array = []
	for dy in range(-radius, radius + 1, SCAN_STRIDE):
		for dx in range(-radius, radius + 1, SCAN_STRIDE):
			var tile := center + Vector2i(dx, dy)
			var logic: Dictionary = _world().get_tile_logic(tile)
			if HarvestResolver.action_for_tile(logic) == "dig" and str(logic.get("biome", "")) == biome:
				found.append({"tile": tile, "logic": logic})
				if found.size() >= CANDIDATES:
					return found
	return found


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


# The prediction-miss step shifts ride note_player_step, which also ticks breeding:
# that tick consumes the SHARED encounter _rng when a pen holds a happy compatible
# pair (the lay scan's randf/randi_range) or a party egg hatches (hatch_egg). The
# field-moves world holds neither, so the shifts are rng-free today — this witness
# FAILS LOUD if that ever drifts, since double-run byte-identity would still pass
# (both runs consume the stream identically) and never self-detect the coupling.
func _rng_free_world() -> bool:
	var runtime = _runtime()
	var pastures: Dictionary = runtime.breeding_runtime.pasture_snapshot()
	for pen_key in pastures.keys():
		var entry: Variant = pastures[pen_key]
		if entry is Dictionary and not ((entry as Dictionary).get("mons", []) as Array).is_empty():
			return false
	for mon_variant in runtime.session.party:
		if mon_variant is Dictionary and bool((mon_variant as Dictionary).get("is_egg", false)):
			return false
	return true


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
