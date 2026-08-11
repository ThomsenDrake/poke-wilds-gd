extends RefCounted

# Legendary dungeon dimensions — the runtime core (plan: legendary_dungeon_dimensions;
# spec: docs/product-specs/world-depth.md § Legendaries). Owns the `active_area` dungeon
# context (a session_state field, additive-persisted): the overworld<->dungeon WARPS off the
# step hook, the single tile-logic RESOLVER both generators bind to (dungeon cells ONLY while
# inside; the landmark consult + entrance stamps while outside), the overworld-sim suppression
# (the in_dungeon gate: the session-holding runtimes read session.active_area directly; only
# music_router wires the Callable), the chamber-legendary stamp on entry (the overworld stamp_legendaries
# REPLACEMENT — new_legendary with the ENTRANCE anchor so removal keys stay world-anchored and
# the entrance ring so guardian_level_for stays deep), the session-scoped hp/stages WHITTLE
# (the retired lairs' _instance_state pattern, keyed by removal key, cleared on world change),
# the Regigigas five-tablet entrance SEAL, the per-dungeon field MUSIC switch, and the dungeon
# encounter-scope facade wild_encounter_draw rides (NEVER a biome-pool alias).
#
# DETERMINISM: NO RandomNumberGenerator anywhere — the warp/stamp paths are pure derivations
# off (world_seed, session); the encounter draws RECEIVE the shared _rng from
# wild_encounter_draw and consume it in the landmark draw shape (the pick_species_for /
# level_for_scope precedent). The chamber entity is stamped (3-arg create), never re-rolled.
#
# TRACES (source "DungeonRuntime"; keys for docs/references/trace-events.md):
#   dungeon_entered {dungeon_id, species_id, entrance_tile, tile}
#   dungeon_exited {dungeon_id, tile, reason: exit|defeat}
#   dungeon_entry_refused {dungeon_id, missing} (the Regigigas seal)
#   dungeon_music {dungeon_id, track, trigger: entry|exit} (the headless witness — the
#   landmark_music precedent: play_track_path is headless-gated and emits nothing)

const DungeonMaps := preload("res://scripts/domain/dungeon_maps.gd")
const DungeonLayouts := preload("res://scripts/domain/dungeon_layouts.gd")
const LegendaryPlacement := preload("res://scripts/domain/legendary_placement.gd")

const DUNGEON_BIOME := "ROCK" # the cave biome id every dungeon cell stamps (biome_defs.gd) — encounter scopes ride the token, never this pool
const OFFMAP_REASON := "The darkness closes in." # the off-map sentinel wall's traversal hint

signal message_requested(text: String) # the seal refusal surfaces on the step that triggers it (main.gd connects the MessageBox)

var _session = null
var _catalog = null
var _trace = null
var _world_gen = null
var _landmark_runtime = null
var _overworld_mons = null
var _music_router = null
var _instance_state: Dictionary = {} # removal key -> {current_hp, attack_stages}: the whittle, session-scoped (cleared on world change, NEVER saved)

func setup(session_state, catalog, trace_logger, world_generator, landmark_runtime, overworld_mons_runtime, music_router) -> void:
	_session = session_state; _catalog = catalog; _trace = trace_logger
	_world_gen = world_generator; _landmark_runtime = landmark_runtime
	_overworld_mons = overworld_mons_runtime; _music_router = music_router

# --- Context (the in_dungeon gate every suppression/refusal seam wires to) ------------------
func in_dungeon() -> bool:
	return _session != null and str(_session.active_area) != ""

func active_dungeon() -> String:
	return str(_session.active_area) if _session != null else ""

# --- The tile-logic resolver (the single choke point; game_runtime + world_view bind here) --
# Inside a dungeon: the hand-authored DungeonMaps cell ONLY (no overworld noise/landmarks;
# off-map tiles seal as theme walls). Outside: the landmark consult FIRST, then the entrance
# stamps (entrances WIN on overlap — near-impossible by construction, the anchors exclude
# landmark footprints). The `dungeon_region` key marks interior cells so world_generator's
# mutation pass skips them (overworld clears/placements at colliding local coords never leak).
func tile_logic_for_active(map_pos: Vector2i, base_logic: Dictionary) -> Dictionary:
	if _session == null:
		return base_logic # pre-setup (a view rebuild racing the runtime): inert, never a wrong-seed stamp
	if in_dungeon():
		return _dungeon_cell_logic(map_pos, base_logic)
	var logic: Dictionary = _landmark_runtime.tile_logic_for_active(map_pos, base_logic)
	var cell: Dictionary = DungeonMaps.entrance_cell_for(int(_session.world_seed), map_pos)
	if cell.is_empty():
		return logic
	return _entrance_logic(cell, logic)

# --- The step hook (game_runtime.note_player_step rides it AFTER landmark's) -----------------
# Stepping on an entrance warp tile warps INTO the dungeon (the Regigigas seal can refuse);
# stepping on the dungeon exit tile warps back to the entrance. The view/avatar re-anchor
# rides main.gd's mid-step guard (the _sync_world_from_runtime path).
func note_player_step() -> void:
	if _session == null:
		return
	if not in_dungeon():
		try_enter_at(_session.player_tile)
	elif _session.player_tile == DungeonMaps.exit_tile_for(str(_session.active_area)):
		exit_dungeon()

# The warp-in entry point (the step hook + the scenario lane): false off a warp tile / sealed.
func try_enter_at(map_pos: Vector2i) -> bool:
	if _session == null or in_dungeon():
		return false
	var warp: Dictionary = DungeonMaps.warp_into_dungeon(int(_session.world_seed), map_pos)
	if warp.is_empty():
		return false
	var dungeon_id := str(warp["dungeon_id"])
	if not _seal_allows(dungeon_id):
		return false
	_session.active_area = dungeon_id
	_session.player_tile = warp["tile"]
	if _overworld_mons != null:
		_overworld_mons.clear_live_entities() # the overworld sim's live entities never leak into dungeon-local coords (the next in-context sync re-derives them on exit)
	_stamp_chamber(dungeon_id)
	_play_music(dungeon_id, "entry")
	_emit("dungeon_entered", {"dungeon_id": dungeon_id, "species_id": DungeonMaps.species_for_dungeon(dungeon_id), "entrance_tile": _t(warp["entrance_tile"]), "tile": _t(_session.player_tile)})
	return true

# The warp out (the exit tile + the white-out dump). "exit" re-lands the player on the
# entrance warp tile; "defeat" leaves them where battle_runtime dumped them (the campsite).
func exit_dungeon(reason: String = "exit") -> void:
	if _session == null or not in_dungeon():
		return
	var dungeon_id := str(_session.active_area)
	_snapshot_chamber(dungeon_id) # the whittle survives the exit (session-scoped)
	if _overworld_mons != null:
		_overworld_mons.clear_live_entities()
	_session.active_area = ""
	if reason == "exit":
		var warp_out: Dictionary = DungeonMaps.warp_out_of_dungeon(dungeon_id, int(_session.world_seed))
		if not warp_out.has("tile"): # unreachable by construction (the entry resolved this anchor); miss-002: failure paths name their cause
			push_warning("DungeonRuntime: no warp-out tile for '%s'; the player keeps the dungeon-local coord" % dungeon_id)
		_session.player_tile = warp_out.get("tile", _session.player_tile)
	_play_music(dungeon_id, "exit")
	_emit("dungeon_exited", {"dungeon_id": dungeon_id, "tile": _t(_session.player_tile), "reason": reason})

# The white-out exit: battle_runtime already dumped the player to the campsite (overworld),
# so the dungeon context closes here — AFTER overworld_mons_runtime.note_battle_outcome wrote
# the whittle onto the entity (game_runtime's call order), so _snapshot_chamber persists it.
func note_battle_outcome(outcome: String, _enemy: Dictionary) -> void:
	if outcome == "defeat":
		exit_dungeon("defeat")

# New game (game_runtime.new_game): the whittle + any stale chamber entity die with the world.
func note_new_world() -> void:
	_instance_state.clear()
	if _overworld_mons != null:
		_overworld_mons.clear_dungeon_entities()

# Save-load re-entry (game_runtime._apply_loaded_payload, AFTER apply_loaded_state): drops the
# pre-load chamber entity, validates the loaded area + walkable tile (bad ids degrade to the
# overworld; bad local coords normalize to spawn), and re-enters the dungeon context.
func note_world_loaded() -> void:
	if _session == null or _overworld_mons == null:
		return
	_overworld_mons.clear_dungeon_entities() # a load always drops the pre-load chamber entity (it re-stamps below subject to suppression)
	var dungeon_id := str(_session.active_area)
	if dungeon_id == "":
		return
	if not DungeonMaps.is_dungeon(dungeon_id):
		_session.active_area = ""
		return
	var loaded_cell: Dictionary = DungeonMaps.cell_for(dungeon_id, _session.player_tile)
	if loaded_cell.is_empty() or not bool(loaded_cell.get("walkable", false)): _session.player_tile = DungeonMaps.spawn_tile_for(dungeon_id)
	_overworld_mons.clear_live_entities() # the loaded context is the dungeon: no overworld entity may linger at dungeon-local coords
	_stamp_chamber(dungeon_id)
	_play_music(dungeon_id, "entry")

# --- The Regigigas seal ----------------------------------------------------------------------
# The warp refuses until the bag holds all five tablets (NEVER consumed); the refusal traces
# and surfaces a message naming how many of the five seal hollows are filled.
func _seal_allows(dungeon_id: String) -> bool:
	if dungeon_id != DungeonLayouts.SEAL_DUNGEON:
		return true
	var missing: Array = []
	for tablet in DungeonLayouts.TABLET_FOR_SPECIES.values():
		if _session.get_item_count(str(tablet)) == 0:
			missing.append(str(tablet))
	if missing.is_empty():
		return true
	missing.sort() # a data-pinned order (dict values() order is insertion-stable, but the payload never rides it)
	_emit("dungeon_entry_refused", {"dungeon_id": dungeon_id, "missing": missing})
	message_requested.emit("The cave mouth is sealed by five hollows. %d of the five tablets are set." % (DungeonLayouts.TABLET_FOR_SPECIES.size() - missing.size()))
	return false

# --- The chamber legendary (the overworld stamp_legendaries replacement) ---------------------
# On entry the species' stationary stamps through overworld_mons_runtime's dungeon seam (the
# sim's new_legendary: kind/battle_kind "legendary" preserved; the tile is the dungeon-local
# chamber; the anchor is the ENTRANCE anchor so removal keys stay world-anchored; the ring is
# the entrance ring so guardian_level_for stays deep). Suppressed when caught (the persistent
# removal set) or KO-cooling-down (the tablet-Regi valve); a lapsed KO mark re-stands FRESH
# (full HP/fresh stages). The session-scoped whittle re-applies on every re-entry.
func _stamp_chamber(dungeon_id: String) -> void:
	if _overworld_mons == null:
		return
	# NO `active` gate: the chamber stamp is the RETIRED boot-time stamp_legendaries' replacement
	# (a direct stamp, never the per-step sim the activation gate guards) — the warp is the opt-in.
	var species_id := DungeonMaps.species_for_dungeon(dungeon_id)
	var anchor: Vector2i = DungeonMaps.entrance_anchor_for(int(_session.world_seed), species_id)
	if anchor == LegendaryPlacement.NO_ANCHOR:
		return
	var key := LegendaryPlacement.removal_key(anchor, species_id)
	if LegendaryPlacement.is_removed(_session.legendary_removals, anchor, species_id):
		return # caught (or MEWTWO/REGIGIGAS KO'd) — gone for good
	if LegendaryPlacement.is_ko_cooling_down(_session.legendary_kos, anchor, species_id, int(_session.total_steps)):
		return # the KO re-stand valve: the Regi rests until REGI_RESTAND_STEPS lapses
	var id := "legendary_%s" % dungeon_id
	if _overworld_mons.has_removed_mark(id): # a tablet Regi's KO mark (session-scoped) lapses WITH the cooldown: re-stand fresh
		_overworld_mons.clear_removed_mark(id); _instance_state.erase(key)
	_overworld_mons.stamp_dungeon_chamber(dungeon_id, species_id, DungeonMaps.chamber_tile_for(dungeon_id), anchor, _entrance_ring(species_id), DUNGEON_BIOME, _instance_state.get(key, {}))

# Persists the chamber entity's hp/stages into the session-scoped whittle (the white-out
# persistence: a defeated player re-enters to the SAME damage; the retired lairs' pattern).
func _snapshot_chamber(dungeon_id: String) -> void:
	if _overworld_mons == null:
		return
	var state: Dictionary = _overworld_mons.chamber_state_for(dungeon_id) # the public seam: the "legendary_%s" id grammar has ONE owner
	if state.is_empty() or (int(state["current_hp"]) <= 0 and int(state["attack_stages"]) <= 0):
		return # no chamber entity, or never battled (a fresh entity carries 0/0): nothing to whittle
	var species_id := DungeonMaps.species_for_dungeon(dungeon_id)
	_instance_state[LegendaryPlacement.removal_key(DungeonMaps.entrance_anchor_for(int(_session.world_seed), species_id), species_id)] = state

func _entrance_ring(species_id: String) -> int:
	for entrance in DungeonMaps.entrances_for_world(int(_session.world_seed)):
		if str(entrance.get("species_id", "")) == species_id:
			return int(entrance.get("ring", 0))
	return 0 # unreachable off a resolved anchor (the stamp's NO_ANCHOR guard ran first)

# --- Encounter scope facade (wild_encounter_draw rides here; delegates outside a dungeon) ----
# Every walkable dungeon cell carries the active dungeon scope (ANYWHERE mode includes
# non-`,` cells); blocked cells keep a tokened-empty refusal, never a biome-pool escape.
# The domain module pins the curated data. Outside a dungeon every call is byte-identical
# to the landmark path.
func encounter_scope_for(tile_pos: Vector2i, fallback_biome: String) -> Dictionary:
	if not in_dungeon():
		return _landmark_runtime.encounter_scope_for(tile_pos, fallback_biome)
	var logic: Dictionary = _world_gen.get_tile_logic(tile_pos) if _world_gen != null else {}
	var token := str(_session.active_area)
	var scope := DungeonMaps.encounter_scope_for(token)
	if scope.is_empty(): scope = {"token": token, "extra_ids": [], "curated": {}}
	if not bool(logic.get("walkable", false)): scope = {"token": token, "extra_ids": [], "curated": {}}
	scope["biome"] = str(logic.get("biome", fallback_biome))
	return scope

# The dungeon pool: the scope's extra_ids (== the sorted curated keys) ONLY — never the biome
# pool. Exactly ONE randi_range draw (the landmark draw shape; the shared _rng order holds).
func pick_species_for(scope: Dictionary, biome_encounters, time_label: String, rng: RandomNumberGenerator) -> String:
	if not in_dungeon():
		return _landmark_runtime.pick_species_for(scope, biome_encounters, time_label, rng)
	var ids: Array = []
	for extra in scope.get("extra_ids", []):
		ids.append(str(extra))
	ids = biome_encounters.battle_viable_ids(_catalog.species, ids) # curated IDs bypass the biome filter
	if not ids.is_empty():
		return str(ids[rng.randi_range(0, ids.size() - 1)])
	return "" # invalid authored scope: no unrelated full-catalog substitute

# The curated band for a curated species (the RUINS_INNER_CURATED precedent); the dungeon-wide
# level_band floors anything else. Exactly ONE draw either way.
func level_for_scope(scope: Dictionary, species_id: String, tile_pos: Vector2i, rng: RandomNumberGenerator) -> int:
	if not in_dungeon():
		return _landmark_runtime.level_for_scope(scope, species_id, tile_pos, rng)
	var curated: Dictionary = scope.get("curated", {}) if scope.get("curated", {}) is Dictionary else {}
	var band: Array = curated.get(species_id, scope.get("level_band", [5, 5]))
	return rng.randi_range(int(band[0]), int(band[1]))

# --- Cell -> logic stamps ---------------------------------------------------------------------
# The interior stamp: the overworld base logic is NOISE at dungeon-local coords, so the biome
# pins to ROCK and the ground re-bases on the theme floor (walkables carry their own texture —
# floor/warp/pedestal; blockers render their wall/ledge/prop over the floor). `dungeon_region`
# marks the cell so world_generator's mutation pass skips it.
func _dungeon_cell_logic(map_pos: Vector2i, base_logic: Dictionary) -> Dictionary:
	var dungeon_id := str(_session.active_area)
	var theme: Dictionary = DungeonLayouts.DUNGEONS.get(dungeon_id, {}).get("theme", {})
	var cell: Dictionary = DungeonMaps.cell_for(dungeon_id, map_pos)
	if cell.is_empty(): # off-map: seal as a theme wall — the player can never leave the map
		cell = {"walkable": false, "encounter": false, "token": "", "prop": str(theme.get("wall", "")), "region": "wall", "reason": OFFMAP_REASON}
	var logic := base_logic.duplicate()
	logic["biome"] = DUNGEON_BIOME
	logic["walkable"] = bool(cell["walkable"])
	logic["encounter"] = bool(cell["encounter"])
	logic["encounter_token"] = str(cell["token"])
	logic["block_reason"] = str(cell["reason"])
	logic["requires_field_move"] = ""
	logic["base_path"] = str(cell["prop"]) if bool(cell["walkable"]) else str(theme.get("floor", ""))
	logic["base_region"] = null
	logic["prop_path"] = "" if bool(cell["walkable"]) else str(cell["prop"])
	logic["prop_region"] = null
	logic["tall_grass_path"] = ""
	logic["tall_grass_key_color"] = ""
	logic["dungeon_id"] = dungeon_id
	logic["dungeon_region"] = str(cell["region"])
	return logic

# The entrance stamp (overworld): mirrors Landmarks.cell_logic_for's shape — the host biome +
# ground stay, the facade prop renders on top, the warp flag + dungeon_id ride along. NO
# dungeon_region: the mutation pass still applies (the landmark-footprint precedent).
func _entrance_logic(cell: Dictionary, logic: Dictionary) -> Dictionary:
	var out := logic.duplicate()
	out["walkable"] = bool(cell["walkable"])
	out["encounter"] = bool(cell["encounter"])
	out["block_reason"] = str(cell["reason"])
	out["requires_field_move"] = ""
	out["prop_path"] = str(cell["prop"])
	out["prop_region"] = null
	out["tall_grass_path"] = ""
	out["tall_grass_key_color"] = ""
	out["dungeon_id"] = str(cell.get("dungeon_id", ""))
	out["dungeon_warp"] = bool(cell.get("warp", false))
	return out

# --- Field music (the landmark_music trace precedent) ------------------------------------------
# Entry plays the per-dungeon track (play_track_path is headless-gated, so the trace is the
# headless witness); exit restores the host biome track at the landing tile (the tower-exit
# precedent, landmark_runtime.gd:220) — active_area is already "" so the router's gate is open.
func _play_music(dungeon_id: String, trigger: String) -> void:
	var track := str(DungeonLayouts.MUSIC.get(dungeon_id, ""))
	if track == "":
		return
	_emit("dungeon_music", {"dungeon_id": dungeon_id, "track": track, "trigger": trigger})
	if _music_router == null:
		return
	if trigger == "entry":
		_music_router.play_track_path(track)
	elif _world_gen != null:
		_music_router.play_biome_track(str(_world_gen.get_tile_logic(_session.player_tile).get("biome", "")))

func _emit(event_name: String, payload: Dictionary) -> void:
	if _trace != null:
		_trace.emit_event(event_name, "DungeonRuntime", payload)

func _t(tile: Vector2i) -> Array:
	return [tile.x, tile.y]
