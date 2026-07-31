extends RefCounted

# Phase 7 Build 3 v5 support EXTRACTED from save_stability_scenario.gd for the app
# 220-line budget (the wild_battle_scenario precedent): (1) the update-mode downshift
# guard — the golden always regenerates as the v4-shape MIGRATION WITNESS (a v5-shaped
# write is REFUSED + traced); (2) the world_chain round-trip sublane — pins the v5 SAVE
# shape ONLY (a new sublane, NOT a golden rewrite): mutate origin (upstream) -> cross ->
# mutate chained -> reload -> BOTH worlds re-canonicalize byte-identically. The runtime
# cross mechanics (entry tile, legendary re-stamp) are pinned by world_chain_scenario.
# Domain access rides the runtime's own preload (the app layer may not preload domain
# directly — check_architecture.gd's layer table; the landmark_flow precedent).
const SessionState := preload("res://scripts/runtime/session_state.gd")
const SaveMigration := SessionState.SaveMigration


# Update mode rewrites the witness DOWNSHIFTED to the v4 shape (SaveMigration.downshift
# — the byte-verbatim inverse of migrate), so the committed golden stays a v4 MIGRATION
# WITNESS migrate() has work to do on. A v5-shaped write (a chained session that cannot
# downshift) is REFUSED with a traced refusal, never silent — a v5 golden would make
# migrate() a no-op and green the proof forever while proving nothing.
static func update_golden(runtime, canon_a: String, canon_str: Callable, write_golden: Callable, ensure: Callable) -> void:
	var live: Variant = JSON.parse_string(canon_a)
	if not (live is Dictionary) or not SaveMigration.can_downshift(live as Dictionary):
		ensure.call(false, "golden: REFUSED to write a v5-shaped witness — chained worlds cannot downshift to the v4 seat")
		runtime.warn("SaveStabilityScenario", "Golden update refused: the live save carries chained worlds; the witness must stay v4-shaped.", {})
		return
	write_golden.call(canon_str.call(SaveMigration.downshift(live as Dictionary)))


# The v5 per-world round-trip: the outgoing origin's mutations file into
# chained_worlds["0,0"], the active identity swaps to the pure-derived (0,-1) world,
# a persisted edit mutates the stored origin maps, and save -> reload -> save keeps
# BOTH worlds canonical-byte-identical (the faithful map<x>,<y> guarantee at the save
# layer: player edits survive crossing + return because they are persisted).
static func world_chain_round_trip(runtime, canon_str: Callable, diff_paths: Callable, ensure: Callable) -> void:
	var session = runtime.session
	var zero_id := SaveMigration.world_id_for(Vector2i.ZERO)
	# The TRUE derived seed, via the runtime's own preload chain (the app layer may not
	# preload domain directly — check_architecture's layer table): world_chain.gd's pure
	# world_seed_for(root, (0,-1)) — the same hash the chaining swap computes on a cross.
	var world_chain: Variant = runtime.world_chain_runtime.WorldChain
	var derived_seed := int(world_chain.world_seed_for(int(session.root_seed), Vector2i(0, -1)))
	session.chained_worlds[zero_id] = {
		"world_overrides": runtime._world_gen.overrides_for_save(),
		"structures": runtime._world_gen.placements_for_save(),
		"campsite_x": session.campsite_tile.x, "campsite_y": session.campsite_tile.y,
		"campsite_pokemon": session.get_campsite_pokemon(),
		"pastures": (session.pastures as Dictionary).duplicate(true),
		"player_x": session.player_tile.x, "player_y": session.player_tile.y}
	session.active_chain = "0,-1"
	session.world_seed = derived_seed
	session.structures = {}; session.pastures = {}; session.campsite_pokemon = []
	runtime._world_gen.setup(int(session.world_seed)); runtime._world_gen.clear_overrides(); runtime._world_gen.clear_placements()
	(session.chained_worlds[zero_id]["structures"] as Dictionary)["60,61"] = {"kind": "placed", "structure_id": "fence", "by": "build", "step": 7}
	runtime.save_game()
	var canon_pre: String = canon_str.call(_payload(runtime))
	var reloaded: Dictionary = runtime.save_store.load_payload()
	if not ensure.call(not reloaded.is_empty() and runtime._apply_loaded_payload(reloaded), "world_chain round-trip: the chained v5 payload failed to re-apply"):
		return
	runtime.save_game()
	var canon_post: String = canon_str.call(_payload(runtime))
	if canon_pre != canon_post:
		var diff: Array = diff_paths.call(JSON.parse_string(canon_pre), JSON.parse_string(canon_post))
		ensure.call(false, "world_chain round-trip: canonical drift across the chained save -> reload -> save (%s)" % "; ".join(PackedStringArray(diff.slice(0, 8))))
	else:
		ensure.call(true, "")
	# BOTH worlds witnessed: the active (0,-1) identity survived + the stored origin edit.
	ensure.call(str(session.active_chain) == "0,-1" and int(session.world_seed) == derived_seed, "world_chain round-trip: the active chain identity did not survive reload")
	var chained_structures: Variant = (session.chained_worlds.get(zero_id, {}) as Dictionary).get("structures", {})
	ensure.call(str((chained_structures as Dictionary).get("60,61", {}).get("structure_id", "")) == "fence", "world_chain round-trip: the chained origin edit did not survive reload")


static func _payload(runtime) -> Dictionary:
	return runtime.session.to_save_payload(runtime._world_gen.overrides_for_save(), runtime._world_gen.placements_for_save())
