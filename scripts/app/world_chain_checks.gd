extends Node

# World chain scenario CHECKS, part 1 (Phase 7 Build 3; world-depth.md § Smoke
# validation's `world_chain`). The crossing sequence + the determinism/chained-world
# proofs: the walk-into-boundary refusal, the first crossing + pure-hash witness, the
# legendary RE-STAMP, any-world landmark hosting (the overworld_mons_checks split
# precedent; part 2 — persistence/beacon/save/control — rides world_chain_persist_
# checks.gd, both under the app 220 wall). The scenario keeps the seed pin + the
# in-scenario double-run fingerprint compare. Domain access rides the runtimes' own
# preloads (the app layer may not reach domain directly — check_architecture's layer
# table). miss-002: every red NAMES its cause; the SCRIPTED crosses drive try_cross_edge
# directly (a cross is a warp), while the avatar case proves the production step trigger.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const WorldChainRuntime := preload("res://scripts/runtime/world_chain_runtime.gd")
const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd")
const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const OverworldMonsProbe := preload("res://scripts/runtime/overworld_mons_probe.gd")
const FieldMovesParty := preload("res://scripts/runtime/field_moves_party.gd")
# Domain access rides the runtime re-exports (the legendary_spawn_scenario precedent).
const WorldChain := WorldChainRuntime.WorldChain
const SaveMigration := WorldChainRuntime.SaveMigration
const Landmarks := LandmarkRuntime.Landmarks
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement

const ORIGIN := Vector2i.ZERO
const CHAINED := Vector2i(0, -1) # crossing North from (0,0) enters (0,-1) (screen-north = -y)
const NORTH := Vector2i.UP
const EDGE_NORTH := Vector2i(0, -95) # manhattan 95 == WORLD_RADIUS - 1: at_edge (the crossing precondition)
# Fixed offsets (base terrain + resolver; empty maps on a fresh derive): the tile-logic
# half of the fingerprint. Deterministic ORDER — the join is the byte compare.
const SAMPLE_TILES := [Vector2i.ZERO, Vector2i(5, 0), Vector2i(-5, 0), Vector2i(0, 5), Vector2i(0, -5), Vector2i(30, 10), Vector2i(-20, 25), Vector2i(42, -42), Vector2i(60, 0), Vector2i(0, 60), Vector2i(-60, 0), Vector2i(0, -60)]

var _ctx: Dictionary = {}
var _runner = null
var _failures: Array = []
var _probe = OverworldMonsProbe.new()
var origin_campsite := Vector2i.MAX # read back by part 2's return case (the restored anchor)
var origin_fence := Vector2i.MAX # the origin edit that must survive crossing + return + save
var derived_witness_ok := false # world_seed == world_seed_for(root, (0,-1)) held on the last run


func setup(ctx: Dictionary, runner, failures: Array) -> void:
	_ctx = ctx; _runner = runner; _failures = failures


func begin_run() -> void: # per double-run half: the script's cross-script memory resets
	origin_campsite = Vector2i.MAX; origin_fence = Vector2i.MAX; derived_witness_ok = false


# The ACTIVE world's fingerprint: every stamped entity (the frozen legendaries — the
# roaming sim rides the dispatcher's inert gate) hashed over sorted ids + a tile-logic
# sample over the fixed offsets. Two identical (root_seed, crossing script) runs must
# yield this BYTE-IDENTICALLY for both worlds (the scenario's derive_ok half).
func world_fingerprint(runtime) -> Dictionary:
	var store: Dictionary = runtime.overworld_mons_runtime._entities
	var ids: Array = store.keys(); ids.sort()
	var entities: Array = []
	for id in ids:
		var e: Dictionary = store[id]
		entities.append("%s|%s|%s|%s|%d" % [str(id), str(e.get("species_id", "")), str(e.get("tile", "")), str(e.get("kind", "")), int(e.get("ring", 0))])
	return {"entities": ";".join(PackedStringArray(entities)), "tiles": _tile_sample(runtime)}


func _tile_sample(runtime) -> String:
	var parts: Array = []
	for tile in SAMPLE_TILES:
		var logic: Dictionary = runtime._world_gen.get_tile_logic(tile)
		parts.append("%d,%d|%s|%s|%s|%s|%s" % [tile.x, tile.y, str(logic.get("biome", "")), str(logic.get("walkable", false)), str(logic.get("prop_path", "")), str(logic.get("landmark_id", "")), str(logic.get("encounter_token", ""))])
	return ";".join(PackedStringArray(parts))


# Teleport to the edge (headless STAGING transport), drive the runtime directly, then
# mirror player_avatar._try_edge_cross's presentation swap — NO tile_changed (a cross
# is a warp). Returns {result, cursor}; cursor scopes the two chain traces.
func cross(runtime, from_tile: Vector2i, direction: Vector2i, method: String, label: String) -> Dictionary:
	_runner.teleport_player(_world(), _player(), runtime, from_tile)
	var cursor: int = _runner.trace_log_line_count()
	var result: Dictionary = runtime.world_chain_runtime.try_cross_edge(direction, method)
	if not _ensure(bool(result.get("ok", false)), "%s: try_cross_edge refused (%s)" % [label, str(result.get("reason", ""))]):
		return {"result": result, "cursor": cursor}
	_player().set_tile_position(result["tile"]); runtime.world_overridden.emit(result["tile"])
	_world().rebuild(int(runtime.get_world_seed())); _world().sync_visible(_player().tile_position)
	return {"result": result, "cursor": cursor}


# Walk-into-boundary refuses traversal_blocked{reason:"world_edge"} (only Surf/Fly
# cross): a party with NEITHER, at the edge, one pressed step PAST the disc.
func run_refusal_case(runtime) -> bool:
	var start: int = _failures.size()
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP"], FieldMovesParty.PARTY_LEVEL) # no Surf, no Fly (field_moves_checks' control precedent)
	_runner.teleport_player(_world(), _player(), runtime, EDGE_NORTH)
	var cursor: int = _runner.trace_log_line_count()
	_player()._try_start_step(NORTH) # the REAL movement gate: (0,-96) leaves the disc -> the pinned refusal
	_ensure(_runner.trace_log_has_since("traversal_blocked", cursor, {"reason": "world_edge"}), "refusal: no traversal_blocked{reason:world_edge} on the walk into the boundary")
	_runner.restore_party(runtime, party_before)
	return _failures.size() == start

# The POSITIVE production-path crossing (the refusal case's mirror): the all-moves
# party pressing a step PAST the disc crosses through player_avatar._try_start_step
# (Surf when water is involved, else Fly) — the live trigger gate the scripted crosses bypass.
func run_avatar_cross_case(runtime) -> bool:
	var start: int = _failures.size()
	var method := "surf" if runtime.party_has_field_move_ability("surf") and (_world().get_tile_biome(EDGE_NORTH) == "WATER" or _world().get_tile_biome(EDGE_NORTH + NORTH) == "WATER") else "fly"
	_runner.teleport_player(_world(), _player(), runtime, EDGE_NORTH); var chain := str(runtime.session.active_chain)
	var cursor: int = _runner.trace_log_line_count()
	_player()._try_start_step(NORTH) # the REAL movement gate: (0,-96) leaves the disc -> production trigger
	_ensure(_runner.trace_log_has_since("world_edge_crossed", cursor, {"chain": chain, "method": method}), "avatar_cross: no world_edge_crossed{%s, %s} from a pressed step past the disc" % [chain, method])
	_ensure(_runner.trace_log_has_since("world_chained", cursor, {"chain": "0,-1", "method": method}), "avatar_cross: no world_chained{0,-1, %s} via the production movement path" % method)
	cross(runtime, Vector2i(0, 95), Vector2i.DOWN, "surf", "avatar_return") # housekeeping: back to origin (cross asserts the swap ok)
	return _failures.size() == start


# The origin edit BEFORE any crossing: a fence near spawn + the campsite anchor that
# the return crossing must restore (faithful "NOT erase … nor reset", fresh-faq.md:184).
func run_origin_edit_case(runtime) -> bool:
	var start: int = _failures.size()
	origin_campsite = runtime.session.campsite_tile
	origin_fence = place_fence(runtime, runtime.session.player_tile)
	_ensure(origin_fence != Vector2i.MAX, "origin_edit: no placeable fence tile near spawn")
	return _failures.size() == start


# Crossing OUT: surf north past the edge -> world_edge_crossed + world_chained, the
# derived seed == world_seed_for(root, (0,-1)) (the PURE-HASH witness), the identity
# swap. The chained fingerprint is taken by the scenario immediately after.
func run_first_cross_case(runtime, root_seed: int) -> bool:
	var start: int = _failures.size()
	var expect_seed: int = WorldChain.world_seed_for(root_seed, CHAINED)
	var info: Dictionary = cross(runtime, EDGE_NORTH, NORTH, "surf", "first_cross")
	var result: Dictionary = info["result"]
	if bool(result.get("ok", false)):
		_ensure(str(result.get("chain", "")) == "0,-1", "first_cross: entered chain %s, expected 0,-1" % str(result.get("chain", "")))
		_ensure(bool(result.get("newly_generated", false)), "first_cross: the FIRST visit to (0,-1) was not newly_generated")
		derived_witness_ok = int(result.get("world_seed", 0)) == expect_seed
		_ensure(derived_witness_ok, "first_cross: world_seed %d != world_seed_for(root, (0,-1)) %d" % [int(result.get("world_seed", 0)), expect_seed])
		_ensure(_runner.trace_log_has_since("world_edge_crossed", info["cursor"], {"chain": "0,0", "direction": [0, -1], "method": "surf"}), "first_cross: no world_edge_crossed{0,0, north, surf}")
		_ensure(_runner.trace_log_has_since("world_chained", info["cursor"], {"chain": "0,-1", "world_seed": expect_seed, "root_seed": root_seed, "method": "surf", "newly_generated": true}), "first_cross: no world_chained{0,-1, derived seed, root, surf, newly_generated}")
		_ensure(str(runtime.session.active_chain) == "0,-1" and int(runtime.session.world_seed) == expect_seed, "first_cross: the session identity did not swap (chain %s, seed %d)" % [str(runtime.session.active_chain), int(runtime.session.world_seed)])
	return _failures.size() == start


# The legendary RE-STAMP witnessed: the chained world's stationary set is EXACTLY
# LegendaryPlacement re-derived for (derived_seed, (0,-1)) — NEITHER origin-stale
# statics NOR empty. REGICE anchors on the derived world's SNOW ring (spec :157 pin;
# a derived-world SNOW-band regression reds HERE, named).
func run_legendary_case(runtime) -> bool:
	var start: int = _failures.size()
	var seed: int = runtime.get_world_seed()
	var store: Dictionary = runtime.overworld_mons_runtime._entities
	var anchored: Array = []
	for species in LegendaryPlacement.LEGENDARY_IDS:
		var sid := str(species)
		var id := "legendary_0,-1:%s" % sid
		var anchor: Vector2i = LegendaryPlacement.anchor_for(seed, CHAINED, sid)
		if anchor == LegendaryPlacement.NO_ANCHOR:
			_ensure(not store.has(id), "legendary: %s resolved NO_ANCHOR in (0,-1) yet entity %s is stamped" % [sid, id])
			continue
		anchored.append(sid)
		var entity: Dictionary = store.get(id, {})
		_ensure(not entity.is_empty() and entity.get("tile", Vector2i.MAX) == anchor, "legendary: %s re-stamp mismatch (entity tile %s vs derived anchor %s)" % [sid, str(entity.get("tile", "")), str(anchor)])
	for id in store.keys():
		if str(id).begins_with("legendary_") and not str(id).begins_with("legendary_0,-1:"):
			_failures.append("legendary: the origin-stale static %s survived the swap" % str(id))
	_ensure(anchored.has("REGICE"), "legendary: REGICE not anchored on the derived world's SNOW ring (spec :157 pin; anchored %s)" % str(anchored))
	return _failures.size() == start


# ANY-WORLD landmark hosting: the derived world hosts all three footprints off
# (derived_seed, (0,-1)) AND the mansion stamp is IN the live terrain (chaining never
# rewrites the generator — the chain-parametric seam serves it).
func run_landmark_hosting_case(runtime) -> bool:
	var start: int = _failures.size()
	var hosted: Array = []; var mansion := {}
	for landmark in Landmarks.landmarks_in_world(runtime.get_world_seed(), CHAINED):
		hosted.append(str(landmark["landmark_id"]))
		if str(landmark["landmark_id"]) == Landmarks.MANSION_ID:
			mansion = landmark
	for landmark_id in Landmarks.LANDMARK_IDS:
		_ensure(hosted.has(landmark_id), "landmark_host: the derived world lacks %s (hosted %s)" % [landmark_id, str(hosted)])
	if _ensure(not mansion.is_empty(), "landmark_host: no mansion footprint in (0,-1)"):
		var footprint: Rect2i = mansion["footprint"]
		var center := footprint.position + Vector2i(int(Landmarks.MANSION_SIZE.x / 2), int(Landmarks.MANSION_SIZE.y / 2))
		_ensure(str(runtime._world_gen.get_tile_logic(center).get("landmark_id", "")) == Landmarks.MANSION_ID, "landmark_host: the mansion footprint is not stamped into the derived terrain at %s" % str(center))
	return _failures.size() == start


# --- shared helpers (part 2 rides cross/place_fence/landmark_in_active/seam) --------
func place_fence(runtime, center: Vector2i) -> Vector2i:
	runtime.session.add_item("log", 20); runtime.session.add_item("dry_soil", 20); runtime.session.add_item("hard_stone", 20) # the fence cost (both biome variants)
	for radius in range(2, 9):
		for tile in _runner.ring_around(center, radius):
			var result: Dictionary = runtime.build_runtime.try_place(tile, "fence", {})
			if bool(result.get("ok", false)):
				return tile
	return Vector2i.MAX


func landmark_in_active(runtime, landmark_id: String) -> Dictionary:
	var chain: Vector2i = SaveMigration.chain_for(str(runtime.session.active_chain))
	for landmark in Landmarks.landmarks_in_world(runtime.get_world_seed(), chain):
		if str(landmark["landmark_id"]) == landmark_id:
			return landmark
	return {}


func seam_unlocked(runtime, chain: Vector2i) -> bool: # the FROZEN seam — the checks never key the save surface directly
	var all: Dictionary = runtime.session.landmark_state_for(chain)
	var raw: Variant = all.get(Landmarks.MANSION_ID, {})
	return bool(Landmarks.mansion_state_from(raw if raw is Dictionary else {}).get("unlocked", false))


func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
