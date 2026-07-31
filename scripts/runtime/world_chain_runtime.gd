extends RefCounted

# Phase 7 Build 3 — world-chain SWAP orchestration + the beacon registry extension
# (world-depth.md § World chaining). EXTRACTED from game_runtime.gd (319/320 wall — only
# instantiation + setup + delegation fit there; the field_move_runtime precedent).
#
# Faithful loop (fresh-faq.md:182-188): Surf/Fly past the farthest edge -> try_cross_edge
# (direction, method). The outgoing world is neither erased nor reset: its mutations (maps
# + landmark_state via the frozen seam) file into chained_worlds["<cx>,<cy>"] (§ Save v5),
# the incoming world re-derives from world_seed_for(root_seed, chain) — PURE SplitMix, NO
# RandomNumberGenerator (check_repo_contracts.py's world_depth_rng_issues bans a
# construction in this file) — then re-applies the incoming world's saved overrides/
# placements/campsite/pastures (an ABSENT entry = a first visit = pure-derived terrain),
# RE-STAMPS its stationary legendaries (the sim drops the previous statics and re-derives
# per (world_seed, chain) minus legendary_removals — the explicit re-stamp that keeps a
# chained world from shipping zero/stale legendaries) and RE-APPLIES its landmark puzzle
# state ALONGSIDE via the frozen seam, repositions the player on the entry edge, and traces
# world_chained. Teleport CANNOT cross worlds: the beacon registry reads the ACTIVE world's
# placements (field_move_runtime.way_stone_tiles), so a beacon list never spans worlds by
# construction (fresh-faq.md:186); edge suppression + beacon_placed live HERE — hooks on
# field_move_runtime (its 320 wall; the Phase-6 overworld-hook precedent).

const WorldChain := preload("res://scripts/domain/world_chain.gd")
const SaveMigration := preload("res://scripts/domain/save_migration.gd")

var _session = null
var _trace = null
var _world_gen = null
var _breeding_runtime = null
# WEAK refs (the overworld_mons_sim WeakRef precedent): field_move_runtime.world_chain_gate
# points BACK here, and overworld_mons_runtime -> field_move_runtime + landmark_runtime ->
# overworld_mons_runtime close the ring — GDScript's RefCounted has NO cycle collector, so
# strong refs leaked the whole runtime cluster at exit. game_runtime owns all three strongly.
var _field_move_ref := WeakRef.new()
var _overworld_mons_ref := WeakRef.new()
var _landmark_ref := WeakRef.new()


func setup(session_state, trace_logger, world_generator, field_move_runtime, overworld_mons_runtime, breeding_runtime, landmark_runtime) -> void:
	_session = session_state; _trace = trace_logger; _world_gen = world_generator
	_breeding_runtime = breeding_runtime
	_field_move_ref = weakref(field_move_runtime) if field_move_runtime != null else WeakRef.new()
	_overworld_mons_ref = weakref(overworld_mons_runtime) if overworld_mons_runtime != null else WeakRef.new()
	_landmark_ref = weakref(landmark_runtime) if landmark_runtime != null else WeakRef.new()
	if field_move_runtime != null: # the Phase-6 hook precedent: ZERO lines of beacon policy at field_move_runtime's wall
		field_move_runtime.beacon_registered_hook = Callable(self, "note_way_stone_registered")
		field_move_runtime.world_chain_gate = self


# --- Edge crossing -------------------------------------------------------------

# Attempts a world-crossing step: direction cardinal, player at the farthest edge, the step
# leaving the disc. Returns {ok, tile, chain, world_seed, newly_generated} on success (the
# caller repositions the presentation); {ok:false, reason} otherwise, changing nothing.
func try_cross_edge(direction: Vector2i, method: String) -> Dictionary:
	if _session == null or not WorldChain.is_cardinal(direction):
		return {"ok": false, "reason": "not_cardinal"}
	var from_tile: Vector2i = _session.player_tile
	if not WorldChain.at_edge(from_tile) or not WorldChain.is_outside(from_tile + direction):
		return {"ok": false, "reason": "not_at_edge"} # the step stays in-extent: ordinary traversal
	var old_id := str(_session.active_chain)
	var old_chain := SaveMigration.chain_for(old_id)
	var new_chain := WorldChain.adjacent_chain(old_chain, direction)
	var new_id := SaveMigration.world_id_for(new_chain)
	var new_seed := WorldChain.world_seed_for(int(_session.root_seed), new_chain)
	_emit("world_edge_crossed", {"tile": _t(from_tile), "chain": old_id, "direction": _t(direction), "method": method})
	_persist_outgoing(old_id)
	var incoming := _take_incoming(new_id) # deep copy + consume the nest (its data goes LIVE)
	var newly_generated := incoming.is_empty() # no stored entry = never visited = pure-derived
	_session.active_chain = new_id # identity swap FIRST: the frozen seam resolves the flat landmark var off it
	_session.world_seed = new_seed
	_world_gen.setup(new_seed) # re-bind the noise channels to the derived seed (NEVER reseeds the shared _rng — the encounter stream is continuous across worlds)
	_world_gen.clear_overrides(); _world_gen.clear_placements()
	var saved_overrides: Variant = incoming.get("world_overrides", {})
	if saved_overrides is Dictionary:
		_world_gen.apply_overrides(saved_overrides) # WorldOverrides.merge_save caps internally (the game_runtime.apply_world_overrides warning is load-path only)
	var saved_structures: Variant = incoming.get("structures", {})
	_session.structures = (saved_structures as Dictionary).duplicate(true) if saved_structures is Dictionary else {}
	_world_gen.apply_placements(_session.structures)
	var raw_campsite: Variant = incoming.get("campsite_pokemon", [])
	_session.campsite_pokemon = (raw_campsite as Array).duplicate(true) if raw_campsite is Array else []
	var raw_pastures: Variant = incoming.get("pastures", {})
	_session.pastures = (raw_pastures as Dictionary).duplicate(true) if raw_pastures is Dictionary else {}
	if _breeding_runtime != null:
		_breeding_runtime.apply_save_state(_session.pastures) # validates AFTER the placements land (the _apply_loaded_payload order)
	var entry_tile := WorldChain.entry_tile_for(new_seed, direction, method == "surf")
	# The incoming entry's player_x/player_y are INTENTIONALLY superseded by the entry
	# edge (contract: "reposition the player on the entry edge") — they persist for v5
	# schema completeness, never to restore a position (do not "fix" this to read them).
	_session.player_tile = entry_tile
	if incoming.has("campsite_x"): # a returning world keeps its anchor; a first visit anchors to the entry (the spawn precedent)
		_session.campsite_tile = Vector2i(int(incoming.get("campsite_x", entry_tile.x)), int(incoming.get("campsite_y", entry_tile.y)))
	else:
		_session.campsite_tile = entry_tile
	# Per-world puzzle re-apply rides the FROZEN seam (active chain -> the flat var); the
	# consumed nest's copy is dropped so the save never double-writes the active world.
	var raw_state: Variant = incoming.get("landmark_state", {})
	_session.set_landmark_state(new_chain, (raw_state as Dictionary).duplicate(true) if raw_state is Dictionary else {})
	var landmark = _landmark_ref.get_ref()
	if landmark != null:
		landmark.note_world_changed() # per-world first-entry/loot one-shots (puzzle state rides the seam, not this)
	var overworld_mons = _overworld_mons_ref.get_ref()
	if overworld_mons != null:
		overworld_mons.stamp_legendaries() # threads session.active_chain: drops the outgoing statics + re-derives per (new_seed, new_chain) minus legendary_removals
		overworld_mons.note_warp(entry_tile) # a cross ends every chase + re-syncs the entity window (the teleport/fly precedent)
	_emit("world_chained", {"chain": new_id, "world_seed": new_seed, "root_seed": int(_session.root_seed), "method": method, "newly_generated": newly_generated})
	return {"ok": true, "tile": entry_tile, "chain": new_id, "world_seed": new_seed, "newly_generated": newly_generated}


# Serializes the ACTIVE world's mutations into chained_worlds[old_id] — EXACTLY the v5
# entry shape (world-depth.md § Save v5); landmark_state omitted when {} ("omitted from an
# entry when {}"). The live maps stay put until the incoming world replaces them.
func _persist_outgoing(old_id: String) -> void:
	var entry: Dictionary = {
		"world_overrides": _world_gen.overrides_for_save(),
		"structures": _world_gen.placements_for_save(),
		"campsite_x": _session.campsite_tile.x, "campsite_y": _session.campsite_tile.y,
		"campsite_pokemon": _session.get_campsite_pokemon(),
		"pastures": (_session.pastures as Dictionary).duplicate(true),
		"player_x": _session.player_tile.x, "player_y": _session.player_tile.y}
	if not (_session.landmark_state as Dictionary).is_empty():
		entry["landmark_state"] = (_session.landmark_state as Dictionary).duplicate(true)
	_session.chained_worlds[old_id] = entry


# Deep-copies the incoming world's stored entry ({} when absent) and ERASES it: its maps/
# puzzle go LIVE on the session + generator, so a leftover nest would double-write the
# active world on save (to_payload re-nests the active landmark_state itself).
func _take_incoming(new_id: String) -> Dictionary:
	var raw: Variant = _session.chained_worlds.get(new_id, {})
	var incoming: Dictionary = (raw as Dictionary).duplicate(true) if raw is Dictionary else {}
	_session.chained_worlds.erase(new_id)
	return incoming


# --- Beacons (the Phase-7 way-stone deltas; fresh-faq.md:178-192) ----------------

# Edge-suppression predicate for field_move_runtime's use_teleport/use_fly gate (injected
# as world_chain_gate): manhattan(player) >= WORLD_RADIUS - TELEPORT_EDGE_MARGIN refuses
# "edge_suppressed" so Teleport can't skip the chain mechanic (the numbers are flagged #12).
func teleport_suppressed() -> bool:
	return _session != null and WorldChain.teleport_suppressed_at(_session.player_tile)


# Hook target: fires beacon_placed {tile, chain, beacon_index} when a way-stone registers
# within TELEPORT_EDGE_MARGIN of the edge — the registry-required trace (an inland stone
# keeps waystone_registered only; beacon == way-stone distinguished by edge proximity).
# beacon_index is the stone's position in beacon_tiles() — the edge-band SELECTOR listing
# order (registration order, inland stones SKIPPED), so the trace EQUALS the selector's
# "Beacon N" row number (ONE ordering, trace + UI — never the full way-stone ordinal).
func note_way_stone_registered(tile: Vector2i) -> void:
	var field_move = _field_move_ref.get_ref()
	if _session == null or field_move == null or not WorldChain.is_beacon_tile(tile):
		return
	_emit("beacon_placed", {"tile": _t(tile), "chain": str(_session.active_chain), "beacon_index": int(beacon_tiles().find(tile))})


# The multi-beacon SELECTOR seam (fresh-faq.md:180 "you can select one of the Beacons";
# closes the last-registered-only divergence #12): edge-band way-stones in REGISTRATION
# order (way_stone_tiles is (step, tile)-ordered). The picker UI rides this + the
# index-addressed field_move_runtime.use_teleport(tile); beacon_index matches this order.
func beacon_tiles() -> Array:
	var field_move = _field_move_ref.get_ref()
	if field_move == null:
		return []
	var beacons: Array = []
	for tile in field_move.way_stone_tiles():
		if WorldChain.is_beacon_tile(tile):
			beacons.append(tile)
	return beacons


func _emit(event_name: String, payload: Dictionary) -> void:
	if _trace != null:
		_trace.emit_event(event_name, "WorldChainRuntime", payload)


func _t(tile: Vector2i) -> Array:
	return [tile.x, tile.y]
