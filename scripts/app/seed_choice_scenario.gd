extends Node

# Seed-choice scenario (infinite-world slice 4; spec: world-depth.md successor
# infinite-world.md slice 4). Witnesses the creation-time seed choice: (1) CUSTOM-SEED
# DETERMINISM — new_game(SEED) bypasses ONLY the world_seed draw (the starter shiny
# draw above it ALWAYS runs first, the pinned stream order): two re-pinned runs
# (seed_for_smoke BEFORE EACH new_game, since each consumes one starter draw from the
# shared _rng) derive byte-identical world_seed/spawn/tile-logic fingerprints over the
# world_invariants stride sample (SCALAR fields only — Rect2 regions don't marshal);
# the party is NEVER compared (the starter shiny roll legitimately differs per pin).
# (2) BEACH SPAWN — under the SAME seed the committed spawn IS the beach pass's first
# match: SAND + walkable + a cardinal surf neighbor (get_tile_logic, the PURE generator
# — never the render cache). (3) RANDOM PATH — the no-arg new_game's world_seed draw is
# stream index 1 (after the starter draw), so a fresh pin lands the HARD-PINNED constant
# (the playtest_entity_soak precedent pair). NOT a double-run consumer; deterministic by
# construction.

const SEED := 2026080401 # custom-seed pin: the beach pass lands spawn (5,4) within SPAWN_SEARCH_RADIUS (probed under the LIVE resolver wiring — origin footprints + the scattered window)
const SEED2 := 2026072810 # random-path pin (the entity-soak pin — DISTINCT from SEED so the random witness can't mask a custom-seed leak)
const RANDOM_WORLD_SEED := 1319840800 # measured: seed_for_smoke(SEED2) + no-arg new_game() — starter shiny draw first, THEN the world_seed draw (playtest_entity_soak_scenario.gd:25)
const SAMPLE_EXTENT := 70
const SAMPLE_STRIDE := 14 # the world_invariants stride sample (the determinism grid)
const SCALAR_FIELDS := ["biome", "requires_field_move", "block_reason", "prop_path"] # the string fields; walkable/encounter ride the bool reads (Rect2 regions NEVER marshal)

var _ctx: Dictionary = {}
var _failures: Array = []
var _oks: Dictionary = {}

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	_oks["determinism_ok"] = _prove_custom_seed(runtime)
	if _failures.is_empty(): _oks["beach_ok"] = _prove_beach_spawn(runtime)
	else: _failures.append("skipped: beach (cascaded from a determinism red)")
	if _failures.is_empty(): _oks["random_ok"] = _prove_random_path(runtime)
	else: _failures.append("skipped: random (cascaded from an earlier red)")
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate()
		payload["pin"] = SEED; payload["seed"] = SEED; payload["random_pin"] = SEED2; payload["random_seed"] = runtime.get_world_seed()
		runtime.emit_trace("seed_choice_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("seed_choice_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("SeedChoiceScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
	_player().input_enabled = true # the restore block: the scenario leaves the avatar drivable whatever the exit path

# CUSTOM-SEED DETERMINISM: two re-pinned new_game(SEED) runs agree on world_seed,
# spawn tile and the full stride-sample fingerprint (each new_game consumes ONE starter
# shiny draw from the shared _rng, so seed_for_smoke re-pins BEFORE each).
func _prove_custom_seed(runtime) -> bool:
	var start: int = _failures.size()
	var first: Dictionary = _custom_seed_run(runtime)
	var second: Dictionary = _custom_seed_run(runtime)
	if not _ensure(int(first.get("world_seed", -1)) == SEED and int(second.get("world_seed", -1)) == SEED, "custom: world_seed %d/%d != the chosen seed %d (the custom-seed path did not bypass ONLY the world_seed draw)" % [int(first.get("world_seed", -1)), int(second.get("world_seed", -1)), SEED]):
		return false
	_ensure(first == second, "custom: two re-pinned runs diverged (spawn %s vs %s — a shared-_rng leak into world gen or an unpinned draw)" % [str(first.get("spawn", Vector2i.MAX)), str(second.get("spawn", Vector2i.MAX))])
	return _failures.size() == start

# One custom-seed run: pin -> new_game(SEED) -> rebuild -> the witness sample.
func _custom_seed_run(runtime) -> Dictionary:
	runtime.seed_for_smoke(SEED) # BEFORE new_game: the starter draw rides the pinned stream
	runtime.new_game(SEED)
	_world().rebuild(runtime.get_world_seed()) # the view owns its own generator (the content_scatter precedent)
	return {"world_seed": runtime.get_world_seed(), "spawn": runtime.get_player_tile(), "tiles": _tile_fingerprint(runtime)}

# The stride-sample fingerprint: SCALAR tile-logic fields only (biome/walkable/
# encounter/requires_field_move/block_reason/prop_path) over the fixed grid — a Rect2
# region would never marshal through a trace payload, so it is never sampled.
func _tile_fingerprint(runtime) -> Array:
	var out: Array = []
	for y in range(-SAMPLE_EXTENT, SAMPLE_EXTENT + 1, SAMPLE_STRIDE):
		for x in range(-SAMPLE_EXTENT, SAMPLE_EXTENT + 1, SAMPLE_STRIDE):
			var pos := Vector2i(x, y)
			var logic: Dictionary = runtime._world_gen.get_tile_logic(pos) # the PURE generator (never the render cache)
			var row: Array = [x, y, bool(logic.get("walkable", false)), bool(logic.get("encounter", false))]
			for field in SCALAR_FIELDS:
				row.append(str(logic.get(field, "")))
			out.append(row)
	return out

# BEACH SPAWN: the committed spawn under SEED IS the beach pass's first match —
# SAND + walkable + a cardinal neighbor requiring surf (fixed direction order).
func _prove_beach_spawn(runtime) -> bool:
	var start: int = _failures.size()
	var spawn: Vector2i = runtime.get_player_tile()
	var logic: Dictionary = runtime._world_gen.get_tile_logic(spawn)
	if not _ensure(str(logic.get("biome", "")) == "SAND", "beach: the spawn tile %s biome %s != SAND (no beach within SPAWN_SEARCH_RADIUS for the pin — the walkable fallback ran; re-pin SEED)" % [str(spawn), str(logic.get("biome", ""))]):
		return false
	if not _ensure(bool(logic.get("walkable", false)), "beach: the spawn tile %s is SAND but not walkable (a footprint stamped over the beach)" % str(spawn)):
		return false
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if str(runtime._world_gen.get_tile_logic(spawn + direction).get("requires_field_move", "")) == "surf":
			return _failures.size() == start
	_ensure(false, "beach: the spawn tile %s has no cardinal surf neighbor (the beach-pass gate regressed)" % str(spawn))
	return false

# RANDOM PATH: re-pin IMMEDIATELY before the no-arg new_game (the world_seed draw is
# stream index 1 — the starter shiny draw consumes index 0) and hard-pin the result.
func _prove_random_path(runtime) -> bool:
	var start: int = _failures.size()
	runtime.seed_for_smoke(SEED2)
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed())
	return _ensure(runtime.get_world_seed() == RANDOM_WORLD_SEED, "random: the no-arg new_game derived world_seed %d != the pinned %d (the starter/world_seed draw order shifted)" % [runtime.get_world_seed(), RANDOM_WORLD_SEED]) and _failures.size() == start

func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok

func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
