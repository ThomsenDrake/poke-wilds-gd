extends Node

# Deterministic CHAINED-world driver for the visual sweep (Phase 7 R11; spec: docs/product-specs/
# world-depth.md § World chaining). STANDALONE satellite, SEPARATE from visual_sweep_world_depth:
# R3's run_playtests sidecar gate (_sidecar_seed_equality_violations) demands ONE deterministic world
# per fresh set, and these shots render the DERIVED world world_seed_for(ROOT,(0,-1)) — a different
# world_seed than the origin shots 31-34 — so they run in their own sweep + registry seed. The derived
# world is entered through the PRODUCTION crossing (world_chain_runtime.try_cross_edge: step north OFF
# the farthest edge — the world_chain_checks.gd:79 precedent), which swaps the chain identity, derives
# + binds the seed off session.root_seed, re-stamps the legendaries, traces world_chained; a result
# whose seed != DERIVED_SEED (!= the registry seed) reds LOUD. NEVER a manual seam swap: the raw 63-bit
# SplitMix mix is NOT a seed (world_seed_for masks to 31 bits). Baselines: (35) the non-origin overworld
# with its RE-ANCHORED tower (chaining was pixel-unwitnessed, trace-only before); (36) a ring>=60
# legendary static AT REST, framed out of its Manhattan-8 sight. NO rng; 35 inert, 36 active. R4 pins.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")
const WorldDepthOracle := preload("res://scripts/app/visual_sweep_world_depth_oracle.gd")
const WorldDepthExpand := preload("res://scripts/app/visual_sweep_world_depth_expand.gd") # shared rest probe + legendary math

const DEFAULT_THRESHOLD_PCT := 0.5
const TOWER_ID := "heart_tower" # the re-anchored landmark the chained shot frames (spec § Landmarks: every world hosts it)
const ROOT_SEED := 2026072907 # the world_depth pin; the chain root this satellite crosses from
const CHAIN := Vector2i(0, -1) # the crossing the plan pins (world_seed_for(ROOT,(0,-1)))
const DERIVED_SEED := 1746331193 # == WorldChain.world_seed_for(ROOT_SEED, CHAIN): SplitMix _mix & 0x7fffffff (31 bits — the raw 63-bit mix is NOT a seed); pinned below against the LIVE crossing + the registry seed
const SPIRAL_CAP := 80 # footprint search bound (the world_depth precedent)
const SHOT_CHAINED := "35_chained_world.png"
const SHOT_GUARDIAN := "36_legendary_guardian.png"
const CRAFTED_STATE := {"world_seed": ROOT_SEED, "time_of_day": 720, "party": [["MACHOP", 30]], "bag": {}} # craft the ORIGIN world; the crossing derives the rest off session.root_seed

var _ctx: Dictionary = {}
var _crafted: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _baselines = VisualSweepBaselines.new() # provides registry_seed() (R3 single-source) + reconcile/craft_state
var _captures = SnapshotCapture.new()
var _base_dir := ""
var _mode := VisualSweepBaselines.MODE_COMPARE
var _threshold_pct := DEFAULT_THRESHOLD_PCT
var _shots: Array = []
var _failures: Array = []
var _pending_oracle: Dictionary = {} # R4: per-shot tile regions (set by a shot, consumed+cleared in _capture)
var _rest_sample := {} # two-sample rest-probe cache (WorldDepthExpand.rest_state)


func run_sweep(ctx: Dictionary, options: Dictionary = {}) -> void:
	_ctx = ctx
	_crafted = _baselines.crafted_state("world_chain", CRAFTED_STATE) # R3: sidecar world_seed single-sourced from SHOT_REGISTRY (== DERIVED_SEED; the crossing assert below pins both to the live domain derivation)
	_mode = str(options.get("mode", VisualSweepBaselines.MODE_COMPARE))
	_threshold_pct = float(options.get("threshold_pct", DEFAULT_THRESHOLD_PCT))
	_base_dir = _baselines.resolve_shot_dir()
	if _base_dir.is_empty():
		_runtime().warn("SmokeScenarios", "World chain sweep found no writable screenshot directory.", {}); return
	_baselines.clear_shots(_base_dir)
	if not _baselines.craft_state(_ctx, _runner, CRAFTED_STATE):
		push_error("World chain sweep could not craft its deterministic state; catalog incomplete."); return
	# The PRODUCTION crossing (world_chain_checks.gd:79 precedent): step north OFF the farthest edge.
	# try_cross_edge swaps the chain identity, derives the seed off session.root_seed, rebinds + clears
	# the generator, re-stamps the legendaries, traces world_chained — the frozen landmark resolver re-derives the derived world's three landmarks off session.active_chain.
	_runtime().session.player_tile = Vector2i(0, -95) # farthest edge: manhattan WORLD_RADIUS - 1
	var cross: Dictionary = _runtime().world_chain_runtime.try_cross_edge(Vector2i.UP, "fly")
	if not bool(cross.get("ok", false)):
		push_error("World chain sweep crossing refused (%s); edge seam broken" % str(cross.get("reason", ""))); return
	if str(cross.get("chain", "")) != "0,-1" or int(cross.get("world_seed", 0)) != DERIVED_SEED \
			or DERIVED_SEED != _baselines.registry_seed("world_chain") or not bool(cross.get("newly_generated", false)):
		push_error("World chain sweep derivation drifted (chain %s seed %d newly %s registry %d); the pinned seed broke" % [str(cross.get("chain", "")), int(cross.get("world_seed", 0)), bool(cross.get("newly_generated", false)), _baselines.registry_seed("world_chain")]); return
	_world().rebuild(int(cross.get("world_seed"))) # the crossing mutates the generator; the caller repositions the view (the production split)
	var previous_window := _baselines.apply_canonical_window_size()
	await _settle(5)
	var saved_chance: float = _player().encounter_chance
	_player().encounter_chance = 0.0 # no grass battles (and no wild-stream draw) during capture
	await _chained_shot()
	await _guardian_shot()
	_player().encounter_chance = saved_chance
	_baselines.restore_window_size(previous_window)
	_finish()


func _chained_shot() -> void:
	var footprint := _find_footprint(TOWER_ID) # the tower re-anchors in EVERY world (spec § Landmarks)
	if footprint.size == Vector2i.ZERO:
		_failures.append("%s: no %s stamp in the chained world %d (any-world anchor seam broken)" % [SHOT_CHAINED, TOWER_ID, DERIVED_SEED]); return
	var player_tile: Vector2i = footprint.position + WorldDepthOracle.TOWER_PLAYER_LOCAL
	if str(_world().get_tile_logic(player_tile).get("landmark_id", "")) != TOWER_ID or not bool(_world().get_tile_logic(player_tile).get("walkable", false)):
		_failures.append("%s: chained chamber tile %s landmark/walkable unexpected (derived layout drift)" % [SHOT_CHAINED, player_tile]); return
	_crafted["chained_root_seed"] = ROOT_SEED
	_crafted["chained_chain"] = [CHAIN.x, CHAIN.y]
	_crafted["tower_footprint"] = [footprint.position.x, footprint.position.y, footprint.size.x, footprint.size.y]
	_crafted["tower_room_tile"] = [player_tile.x, player_tile.y]
	_runner.teleport_player(_world(), _player(), _runtime(), player_tile)
	_world().set_time_of_day(int(CRAFTED_STATE["time_of_day"]))
	_world().sync_visible(player_tile)
	# Re-anchored landmark pixels: the tower's wall/decor tiles in the derived world (the proof the
	# non-origin overworld rendered with its OWN anchors, not the origin's).
	var ink_tiles: Array = []
	for local in WorldDepthOracle.TOWER_INK_LOCALS:
		ink_tiles.append(footprint.position + local)
	_pending_oracle = WorldDepthOracle.dynamic_region(ink_tiles, footprint.position + WorldDepthOracle.TOWER_INK_LOCALS[0], player_tile, true)
	await _capture(SHOT_CHAINED)


func _guardian_shot() -> void:
	var mons: Object = _runtime().get("overworld_mons_runtime")
	if mons == null or not mons.has_method("stamp_legendaries"):
		_failures.append("%s: overworld_mons_runtime.stamp_legendaries absent (legendary seam broken)" % SHOT_GUARDIAN); return
	var saved_active: bool = WorldDepthExpand.set_entities_active(self, true) # opt in so the entity layer renders the statics
	mons.stamp_legendaries() # the crossing already stamped; this idempotent re-derive (threads the derived chain) is the seam probe
	var target: Dictionary = WorldDepthExpand.pick_legendary(mons, Vector2i.ZERO, WorldDepthExpand.LEGENDARY_SCAN_HALF, WorldDepthExpand.GUARDIAN_RING_MIN)
	if target.is_empty():
		WorldDepthExpand.set_entities_active(self, saved_active)
		_failures.append("%s: no ring>=%d legendary in the chained world (legendary anchor seam broken)" % [SHOT_GUARDIAN, WorldDepthExpand.GUARDIAN_RING_MIN]); return
	var legendary_tile: Vector2i = target.get("tile", Vector2i.MAX)
	var player_tile: Vector2i = WorldDepthExpand.walkable_near(_world(), legendary_tile + WorldDepthExpand.GUARDIAN_PLAYER_OFFSET)
	if player_tile == Vector2i.MAX:
		WorldDepthExpand.set_entities_active(self, saved_active)
		_failures.append("%s: no walkable camera tile near the guardian %s (framing broken)" % [SHOT_GUARDIAN, legendary_tile]); return
	_runner.teleport_player(_world(), _player(), _runtime(), player_tile)
	_world().set_time_of_day(int(CRAFTED_STATE["time_of_day"]))
	_world().sync_visible(player_tile)
	var in_view: Array = mons.live_entities_in(WorldDepthExpand.screen_tile_rect(player_tile))
	var ink_tiles: Array = []
	for entity in in_view:
		if str((entity as Dictionary).get("kind", "")) == WorldDepthExpand.LEGENDARY_KIND:
			ink_tiles.append((entity as Dictionary).get("tile", Vector2i.MAX))
	_crafted["guardian_species"] = str(target.get("species_id", ""))
	_crafted["guardian_tile"] = [legendary_tile.x, legendary_tile.y]
	_crafted["guardian_ring"] = int(target.get("ring", 0))
	_crafted["guardian_camera_tile"] = [player_tile.x, player_tile.y]
	_pending_oracle = WorldDepthOracle.dynamic_region(ink_tiles, legendary_tile, player_tile, true)
	await _capture(SHOT_GUARDIAN)
	WorldDepthExpand.set_entities_active(self, saved_active)


# Footprint discovery: the world_depth spiral (anchors ring around the derived origin; probed
# through the view). Deterministic in the derived seed; ZERO on cap exhaustion (loud-failed).
func _find_footprint(landmark_id: String) -> Rect2i:
	for radius in range(SPIRAL_CAP + 1):
		for cell in _spiral_ring(radius):
			if str(_world().get_tile_logic(cell).get("landmark_id", "")) == landmark_id:
				return _expand_footprint(landmark_id, cell)
	return Rect2i()


func _spiral_ring(radius: int) -> Array:
	if radius == 0:
		return [Vector2i.ZERO]
	var cells: Array = []
	for i in range(-radius, radius + 1):
		cells.append_array([Vector2i(i, -radius), Vector2i(i, radius), Vector2i(-radius, i), Vector2i(radius, i)])
	return cells


func _expand_footprint(landmark_id: String, hit: Vector2i) -> Rect2i:
	var min_x := hit.x
	var max_x := hit.x
	var min_y := hit.y
	var max_y := hit.y
	while str(_world().get_tile_logic(Vector2i(min_x - 1, hit.y)).get("landmark_id", "")) == landmark_id: min_x -= 1
	while str(_world().get_tile_logic(Vector2i(max_x + 1, hit.y)).get("landmark_id", "")) == landmark_id: max_x += 1
	while str(_world().get_tile_logic(Vector2i(hit.x, min_y - 1)).get("landmark_id", "")) == landmark_id: min_y -= 1
	while str(_world().get_tile_logic(Vector2i(hit.x, max_y + 1)).get("landmark_id", "")) == landmark_id: max_y += 1
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


func _capture(filename: String) -> void:
	_message_box().hide_message()
	await _settle(8) # let the render/entity layer reconcile onto logic tiles (byte-stable rest)
	var metadata: Dictionary = RenderIntrospection.collect(_ctx, filename, _crafted)
	WorldDepthOracle.merge_into(metadata, _pending_oracle) # R4: bake the projected tile regions into the sidecar
	_pending_oracle = {}
	var result: Dictionary = await _captures.capture(_runtime(), get_viewport(), filename,
		{"save_path": "%s/%s" % [_base_dir, filename], "metadata": metadata, "rest_probe": Callable(WorldDepthExpand, "rest_state").bind(self)})
	if not result.ok:
		_failures.append("%s: %s (%s)" % [filename, result.kind, result.detail]); return
	_shots.append(filename)


func _finish() -> void:
	if not _failures.is_empty():
		push_error("World chain sweep failed captures: %s" % "; ".join(PackedStringArray(_failures))); return
	if _shots.is_empty():
		_runtime().warn("SmokeScenarios", "World chain sweep captured no shots; nothing verified.", {}); return
	var result: Dictionary = _baselines.reconcile(_shots, _base_dir, _mode, _threshold_pct)
	var per_shot: Dictionary = result.get("per_shot", {})
	var covered := str(result.get("mode", "")) == VisualSweepBaselines.MODE_UPDATE
	for shot in _shots:
		covered = covered or per_shot.has(str(shot))
	result["ok"] = covered and (result.get("errors", []) as Array).is_empty() and (result.get("mismatched", []) as Array).is_empty()
	_report(result)


func _report(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		var per_shot: Dictionary = result.get("per_shot", {})
		for shot in result.get("mismatched", []):
			push_error("World chain sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), _threshold_pct])
		for message in result.get("errors", []):
			push_error("World chain sweep diff error: %s" % message)
		if (result.get("mismatched", []) as Array).is_empty() and (result.get("errors", []) as Array).is_empty():
			push_error("World chain sweep reconcile returned not-ok without a named cause (miss-002): %s" % result)
		return
	_runtime().emit_trace("visual_sweep_world_chain_passed", "SmokeScenarios", {
		"shots": _shots, "mode": str(result.get("mode", VisualSweepBaselines.MODE_COMPARE)),
		"auto_update": bool(result.get("auto_update", false)), "compared": int(result.get("compared", 0)),
		"mismatched": result.get("mismatched", []), "max_drift_pct": float(result.get("max_drift_pct", 0.0)),
		"threshold_pct": _threshold_pct, "base_dir": _base_dir, "crafted": _crafted, "chain": [CHAIN.x, CHAIN.y],
		"sidecar_paths": _shots.map(func(shot_name): return "%s/%s%s" % [_base_dir, shot_name, RenderIntrospection.SIDECAR_SUFFIX])
	})


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
func _message_box() -> Node: return _ctx["message_box"]
