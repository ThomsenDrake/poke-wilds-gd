extends RefCounted

# Repeating legendary LAIRS — the window-scoped lifecycle (infinite-world slice 3; spec:
# docs/product-specs/world-depth.md § Legendaries). Extracted from overworld_mons_sim.gd
# at its 320 wall (the field_action_router/input_router precedent). The frozen origin
# seven stay world-fixed window-exempt statics (byte-identical pins); BEYOND the reach
# box, lairs REPEAT per affinity-biome chunk (flagged divergence — see
# legendary_placement.gd's header). This module owns: per-chunk spawn derivation (cached,
# window-bounded), the out-of-band cull (non-permanent: lairs re-derive on return), and
# the session-scoped instance-state map (a white-out's persisted HP/stages survive a
# cull+return, the :284 contract for lairs). KO/catch removal stays persistent via
# session.legendary_removals (anchor-keyed) and rides note_battle_outcome, unchanged.

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd")
const LegendaryPlacement := preload("res://scripts/domain/legendary_placement.gd")
const ContentScatter := preload("res://scripts/domain/content_scatter.gd")

const LAIR_WINDOW_TILES := 32 # the band's chunk coverage (DESPAWN_CELLS 3 x 8 + margin)

var _rt_ref: WeakRef = null
var _instance_state: Dictionary = {} # "ax,ay:SPECIES" -> {current_hp, attack_stages} — session-scoped, never saved

func setup(runtime_ref) -> void:
	_rt_ref = weakref(runtime_ref)


# The lair id grammar (distinct from the origin seven's "legendary_0,0:SPECIES" — the
# scenario pins stay byte-identical; the anchor tile makes every lair instance unique).
static func lair_id(anchor: Vector2i, species_id: String) -> String:
	return "legendary_lair_%d,%d:%s" % [anchor.x, anchor.y, species_id]


static func is_lair_id(id: String) -> bool:
	return id.begins_with("legendary_lair_")


# World-change reset (called from the sim's stamp_legendaries): the session-scoped damage/
# stages map belongs to the PREVIOUS world's lairs — drop it so a new/load world's lairs
# start fresh (the entity wipe in stamp_legendaries is the entity half of this reset).
func clear_instance_state() -> void:
	_instance_state.clear()


# Per-step window sync (called from the sim's sync_window after the slot/nest spawns):
# cull out-of-band lairs (the sim's own distance sweep exempts ALL kind=="legendary", lairs
# included, so THIS pass owns the lair cull via is_lair_id), then spawn every lair whose
# chunk overlaps the band.
func sync_lairs(player_tile: Vector2i) -> void:
	var rt = _rt_ref.get_ref()
	if rt == null:
		return
	var player_cell := OverworldMons.cell_for_tile(player_tile)
	for entity in rt._live_list(): # cull out-of-band lairs (non-permanent: they re-derive on return)
		if is_lair_id(str(entity.get("id", ""))) and not OverworldMons.in_spawn_band(entity.cell, player_cell):
			rt._remove_entity(entity, OverworldMons.REASON_DISTANCE, false)
	var seed := int(rt._session.world_seed)
	for chunk in ContentScatter.chunks_in_window(player_tile, LAIR_WINDOW_TILES):
		_spawn_chunk_lairs(rt, seed, chunk)


# The battle-outcome seam: persist hp/stages for a LAIR entity so a disengage + cull +
# return keeps the white-out whittle (the origin seven never cull, so they never need it).
func note_instance_state(entity: Dictionary) -> void:
	if not is_lair_id(str(entity.get("id", ""))):
		return
	_instance_state[LegendaryPlacement.removal_key(entity.get("anchor", entity.get("tile", Vector2i.ZERO)), str(entity.get("species_id", "")))] = {
		"current_hp": int(entity.get("current_hp", 0)),
		"attack_stages": int(entity.get("attack_stages", 0)),
	}


func _spawn_chunk_lairs(rt, seed: int, chunk: Vector2i) -> void:
	for species_id in LegendaryPlacement.LEGENDARY_IDS:
		var sid := str(species_id)
		var tile := LegendaryPlacement.lair_for_chunk(seed, chunk, sid, rt._session.legendary_removals)
		if tile == LegendaryPlacement.NO_ANCHOR:
			continue
		var id := lair_id(tile, sid)
		if rt._entities.has(id) or rt._removed.has(id):
			continue # standing, or KO/catch-removed this session (the persistent set re-suppresses on reload)
		if not rt.entity_at(tile).is_empty():
			continue # occupied-tile exclusion (the _find_anchor precedent): two same-affinity lairs never stack a tile
		var entity: Dictionary = rt._sim.new_legendary(id, Vector2i.ZERO, sid, tile, LegendaryPlacement.affinity_for(sid), LegendaryPlacement.ring_of(tile))
		entity["lair"] = true
		var state: Dictionary = _instance_state.get(LegendaryPlacement.removal_key(tile, sid), {})
		if not state.is_empty(): # a culled lair returns with its persisted damage/stages (:284)
			entity["current_hp"] = int(state.get("current_hp", 0))
			entity["attack_stages"] = int(state.get("attack_stages", 0))
		rt._entities[id] = entity
		rt._sim._trace_spawned(entity)
