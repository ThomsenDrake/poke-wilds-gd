extends RefCounted

# Phase 7 Build 1 — landmark runtime (spec: docs/product-specs/world-depth.md § Landmarks,
# § Persistence, § Smoke validation). Entry detection on player step (the one-shot
# landmark_entered per footprint/region + the Heart Tower field-music switch), the Mansion
# puzzle interaction dispatch (statue toggles + the key-gated room door), the footprint-local
# encounter scope fed to game_runtime.generate_wild_encounter (the dormant PKMNMANSION /
# RUINS_* tokens), the mansion door walkability overlay (stamped THROUGH the generator's
# resolver seam so every get_tile_logic consumer sees puzzle state), and the Ruins
# Underground's always-aggressive Dusclops — wired through the Phase-6 stationary-entity
# mechanism (overworld-pokemon.md:26 dormant -> LIVE; wiki-overworld-encounters.md:270).
#
# FROZEN SEAM DISCIPLINE: puzzle state is read/written ONLY through
# session.landmark_state_for(chain) / session.set_landmark_state(chain, state) — NEVER the
# keying — so Build 3's per-world relocation under chained_worlds touches ZERO lines here.
# NO RandomNumberGenerator anywhere: the scope NARROWS the pool, but every draw rides the
# injected shared _rng in the existing order (spec § Determinism: a landmark walk perturbs
# the stream exactly as a same-length grass walk). Chain is (0,0) in Build 1 (origin); the
# swap point is _chain() ONLY.

const Landmarks := preload("res://scripts/domain/landmarks.gd")
const LandmarkScatter := preload("res://scripts/domain/landmark_scatter.gd") # scattered instances beyond the origin core (slice 3; composed at the resolver boundary)
const ContentScatter := preload("res://scripts/domain/content_scatter.gd") # the instance-key parse (slice 3)
const OverworldMons := preload("res://scripts/domain/overworld_mons.gd")
const DayPhase := preload("res://scripts/domain/day_phase.gd")
const EncounterSelection := preload("res://scripts/domain/encounter_selection.gd")

const TOWER_TRACK := "res://assets/source/music/Wilds_HeartTower.ogg" # Calm variant + trigger DEFERRED (spec § Heart Tower; FLAGGED #7)
const DUSCLOPS_ID := "landmark_dusclops_%d,%d" # per-cell guardian-shaped id (the sim's guardian id grammar)
# Mansion interact locals — mirror landmarks.gd _M_SPECIAL (private there; runtime arms read world tiles off the footprint).
const ROOM_DOOR_LOCAL := Vector2i(7, 5)
const SEWER_DOOR_LOCAL := Vector2i(4, 5)
const JOURNAL_STUDY_LOCAL := Vector2i(6, 6)
const UNDERGROUND_GUARD_LOCAL := Vector2i(10, 5) # ruins underground floor (_R_SPECIAL walkable)
const GUARDIAN_SCAN_TILES := 96 # slice 3: scattered-ruins guardian scan half-extent (spawn band + footprint + margin)

var _session = null
var _catalog = null
var _trace = null
var _world_gen = null
var _biome_encounters = null
var _overworld_mons = null
var _music_router = null
var _visited: Dictionary = {} # "landmark_id|region" -> true; session-scoped first_entry (transient by design — the Phase-6 stance)
var _loot_taken: Dictionary = {} # session-scoped loot one-shot; the frozen puzzle shape carries no loot key (spec § Scope: loot tables future)
var _current_landmark := ""
var _current_region := ""

func setup(session_state, catalog, trace_logger, world_generator, biome_encounters, overworld_mons_runtime, music_router) -> void:
	_session = session_state; _catalog = catalog; _trace = trace_logger
	_world_gen = world_generator; _biome_encounters = biome_encounters
	_overworld_mons = overworld_mons_runtime; _music_router = music_router

# --- Generator seam binding (world-depth.md § Landmarks) ---------------------------
# game_runtime + world_view point their WorldGenerator.landmark_resolver here. Stamps the
# footprint into base logic, then overlays the mansion door walkability FROM PUZZLE STATE
# so the single mutation boundary is the single choke point (view, movement, audits).
func tile_logic_for_active(map_pos: Vector2i, base_logic: Dictionary) -> Dictionary:
	if _session == null:
		return base_logic # pre-setup (a view rebuild racing the runtime): inert, never a wrong-seed stamp
	var logic: Dictionary = Landmarks.tile_logic_for(_world_seed(), _chain(), map_pos, base_logic)
	logic = LandmarkScatter.tile_logic_for_window(_world_seed(), map_pos, logic) # slice 3: scattered instances (inert inside the origin core)
	if str(logic.get("landmark_id", "")) != Landmarks.MANSION_ID:
		return logic
	var region := str(logic.get("landmark_region", "")) # stamped by the consult (no second lookup)
	if region != "room_door" and region != "sewer_door":
		return logic
	if not Landmarks.mansion_door_walkable(_mansion_state(str(logic.get("landmark_instance", ""))), region):
		return logic
	logic["walkable"] = true
	logic["block_reason"] = "" # open doors carry no refusal (the traversal hint dies with the reason)
	return logic

# One overworld step: region first-entry traces + tower music, then the ruins guardian.
func note_player_step(player_tile: Vector2i) -> void:
	if _session == null or _in_dungeon(): # dungeon-gated: inside a dungeon the step's tile is dungeon-LOCAL — the overworld footprints never see it
		return
	_note_region(player_tile)
	_ensure_ruins_guardian(player_tile)

# --- Mansion puzzle arms (called by landmark_actions; {} -> not this arm) -----------
func interact(faced: Vector2i) -> Dictionary:
	if _in_dungeon(): return {} # a dungeon-LOCAL faced tile never reaches the overworld puzzle arms (statue/key/journal/loot)
	var arms := [interact_statue, use_key_at, interact_journal, interact_loot, interact_decor]
	for arm in arms:
		var result: Dictionary = arm.call(faced)
		if bool(result.get("handled", false)):
			return result
	return {}

func interact_statue(faced: Vector2i) -> Dictionary:
	var mansion := _mansion_at(faced) # instance-aware (slice 3): a SCATTERED mansion's statue resolves too
	if mansion.is_empty(): return {"handled": false}
	var index := Landmarks.mansion_statue_index_local(faced - mansion["origin"])
	if index < 0: return {"handled": false}
	var key: String = mansion["key"] # the faced statue's instance
	var result: Dictionary = Landmarks.toggle_mansion_statue(_mansion_state(key), index)
	var payload: Dictionary = result.get("payload", {}) if result.get("payload", {}) is Dictionary else {}
	if payload.is_empty(): # out-of-range: skip LOUDLY (miss-002 — every failure path names its cause)
		_warn("Statue toggle skipped: index out of range.", {"tile": _t(faced), "index": index})
		return {"handled": true, "message": "The statue does not budge."}
	_write_mansion(key, result.get("state", {}))
	_emit("puzzle_state_changed", payload)
	var solved := bool(payload.get("solved", false))
	return {"handled": true, "solved": solved, "refresh": _door_tiles(faced),
		"message": "The basement seal grinds open somewhere below!" if solved else "The statue clicks. Its eyes stay lit."}

# Z on the room door: key-gated (the key is a BAG item from the interior table).
func use_key_at(faced: Vector2i) -> Dictionary:
	if not _is_mansion_local(faced, ROOM_DOOR_LOCAL):
		return {"handled": false}
	var key: String = _mansion_at(faced)["key"]
	if bool(_mansion_state(key).get("key_taken", false)):
		return {"handled": true, "message": "The room door stands open."}
	if _session.get_item_count(Landmarks.MANSION_KEY_ID) <= 0:
		return {"handled": true, "message": "The room door is locked. A brass keyhole glints."}
	if not _session.remove_item(Landmarks.MANSION_KEY_ID, 1):
		return {"handled": true, "message": "The room door is locked."}
	var result: Dictionary = Landmarks.take_mansion_key(_mansion_state(key))
	_write_mansion(key, result.get("state", {}))
	_emit("key_item_used", result.get("payload", {}) if result.get("payload", {}) is Dictionary else {}) # auxiliary trace (documented, not registry-required)
	return {"handled": true, "refresh": _door_tiles(faced), "message": "The Mansion Key turns. The room door swings open."}

# Lore pickups — flavor is PORT-WRITTEN (the scrapes give no journal text; FLAGGED #8).
func interact_journal(faced: Vector2i) -> Dictionary:
	var at_table := _is_mansion_local(faced, Landmarks.MANSION_KEY_TABLE_TILE)
	var at_study := _is_mansion_local(faced, JOURNAL_STUDY_LOCAL)
	if not at_table and not at_study:
		return {"handled": false}
	if at_table and _session.get_item_count(Landmarks.MANSION_KEY_ID) == 0 and not bool(_mansion_state(_mansion_at(faced)["key"]).get("key_taken", false)):
		return _take_key(faced) # the key lies beside this journal; pickup precedes lore
	var text := "\"...the three guardians must all burn bright before the seal below will yield.\"" if at_table else "\"...they built the laboratory beneath the courtyard. What grew down there was no accident.\""
	return {"handled": true, "message": text}

func interact_loot(faced: Vector2i) -> Dictionary:
	if not _is_mansion_local(faced, Landmarks.MANSION_LOOT_TILE):
		return {"handled": false}
	var loot_key: String = _mansion_at(faced)["key"] + "|courtyard_shelf" # per-instance one-shot (every scattered mansion has its own shelf)
	if _loot_taken.has(loot_key):
		return {"handled": true, "message": "Only dust left on the shelf."}
	_loot_taken[loot_key] = true
	_session.add_item(Landmarks.MANSION_LOOT_BALL_ID, 1) # FLAGGED #11: Ultra Ball until Phase 8 ball tiers
	return {"handled": true, "message": "A %s rolls off the dusty shelf." % Landmarks.MANSION_LOOT_BALL_ID}

# Ruins glowing statues + the underground painting (decorative; glow BEHAVIOR undocumented — the port renders a static emissive frame, FLAGGED). Mansion walls fall through.
func interact_decor(faced: Vector2i) -> Dictionary:
	var logic: Dictionary = tile_logic_for_active(faced, {}) # composed consult (slice 3): a scattered ruins' statue/painting answers too
	if str(logic.get("landmark_id", "")) == "":
		return {"handled": false}
	match str(logic.get("block_reason", "")):
		"A glowing statue hums.":
			return {"handled": true, "message": "The statue hums. Its glow never fades."}
		"An ancient painting.":
			return {"handled": true, "message": "A painting of something winged, wreathed in fire."}
	return {"handled": false}

# --- Encounter scope (world-depth.md § The dormant tokens) --------------------------
# Outside every footprint -> {"token": ""} and generate_wild_encounter is byte-identical
# to pre-Phase-7 (the alias table stays untouched; scope is footprint-LOCAL).
func encounter_scope_for(tile_pos: Vector2i, fallback_biome: String) -> Dictionary:
	var logic: Dictionary = _world_gen.get_tile_logic(tile_pos) if _world_gen != null else {}
	var token := str(logic.get("encounter_token", ""))
	if token == "":
		return {"token": "", "biome": fallback_biome}
	var scope := {"token": token, "biome": str(logic.get("biome", fallback_biome)),
		"landmark_id": str(logic.get("landmark_id", "")), "region": str(logic.get("landmark_region", "")),
		"extra_ids": [], "curated": {}}
	if token == Landmarks.TOKEN_RUINS_INNER: # faithful Lunatone pool + FLAGGED #9 curated high-level statics
		scope["extra_ids"] = Landmarks.RUINS_INNER_CURATED.keys()
		scope["curated"] = Landmarks.RUINS_INNER_CURATED
	return scope

# Mirrors EncounterSelection.pick_wild_species' draw shape EXACTLY (filter -> ONE
# randi_range over the sorted pool) with the token scope + curated additions threaded in.
func pick_species_for(scope: Dictionary, biome_encounters, time_label: String, rng: RandomNumberGenerator) -> String:
	var biome := str(scope.get("biome", ""))
	var filtered: Dictionary = biome_encounters.filter_species_ids(_catalog.species, biome, time_label, str(scope.get("token", "")))
	if bool(filtered.get("used_fallback", false)) and _trace != null:
		_trace.warning("GameRuntime", "Biome encounter filter fell back to the full catalog.", {"biome": biome, "reason": str(filtered.get("reason", ""))}) # pin-safe source/wording
	var ids: Array = []
	for species_id in filtered.get("ids", []):
		ids.append(str(species_id))
	for extra in scope.get("extra_ids", []):
		ids.append(str(extra))
	ids = biome_encounters.battle_viable_ids(_catalog.species, ids) # scope additions bypass filter_species_ids
	if not ids.is_empty():
		return str(ids[rng.randi_range(0, ids.size() - 1)])
	return _catalog.get_random_encounter_species(rng)

# Exactly ONE rng draw per encounter — the same shape as level_from_distance's
# randi_range(0,3) — so landmark walks consume the shared stream in the existing order.
func level_for_scope(scope: Dictionary, species_id: String, tile_pos: Vector2i, rng: RandomNumberGenerator) -> int:
	var curated: Dictionary = scope.get("curated", {}) if scope.get("curated", {}) is Dictionary else {}
	if curated.has(species_id):
		var band: Array = curated[species_id]
		return rng.randi_range(int(band[0]), int(band[1])) # RUINS_INNER_CURATED 38-45
	match str(scope.get("token", "")):
		"":
			return EncounterSelection.level_from_distance(tile_pos, rng)
		Landmarks.TOKEN_MANSION:
			return rng.randi_range(int(Landmarks.MANSION_LEVEL_BAND[0]), int(Landmarks.MANSION_LEVEL_BAND[1]))
		Landmarks.TOKEN_RUINS_OUTER:
			return rng.randi_range(int(Landmarks.RUINS_OUTER_LEVEL_BAND[0]), int(Landmarks.RUINS_OUTER_LEVEL_BAND[1]))
		Landmarks.TOKEN_RUINS_INNER:
			return Landmarks.RUINS_INNER_LEVEL_FLOOR + rng.randi_range(0, 3) # floor 30 + distance-shaped jitter
	return EncounterSelection.level_from_distance(tile_pos, rng)

# --- Entry traces + tower music ------------------------------------------------------
func _note_region(player_tile: Vector2i) -> void:
	var logic: Dictionary = tile_logic_for_active(player_tile, {}) # the composed consult (origin three + scattered)
	var landmark_id := str(logic.get("landmark_id", ""))
	var region := str(logic.get("landmark_region", "")) if landmark_id != "" else ""
	if landmark_id == _current_landmark and region == _current_region:
		return
	var previous := _current_landmark
	_current_landmark = landmark_id
	_current_region = region
	if landmark_id == "":
		if previous == Landmarks.TOWER_ID and _music_router != null and _world_gen != null:
			_music_router.play_biome_track(str(_world_gen.get_tile_logic(player_tile).get("biome", ""))) # restore the host theme on exit
		return
	var instance := str(logic.get("landmark_instance", landmark_id)) # per-instance first-entry (a second tower's entry + music still fire)
	var key := instance + "|" + region
	var first := not _visited.has(key)
	_visited[key] = true
	_emit("landmark_entered", {"landmark_id": landmark_id, "tile": _t(player_tile), "region": region, "first_entry": first, "instance": instance})
	if landmark_id == Landmarks.TOWER_ID and first:
		_emit("landmark_music", {"landmark_id": landmark_id, "track": TOWER_TRACK, "trigger": "entry"}) # trace seam for the field-music switch: play_track_path is headless-gated + emits nothing, so this trace is the headless witness
		if _music_router != null:
			_music_router.play_track_path(TOWER_TRACK) # the audio itself (headless never plays)

# --- Ruins Underground guardian (Phase-6 dormant -> LIVE) ----------------------------
# wiki-overworld-encounters.md:270 lists Dusclops-in-the-Ruins-Underground ALWAYS-AGGRESSIVE;
# overworld-pokemon.md:26 held it DORMANT until a ruins sub-region existed. It rides the
# sim's stationary-entity record shape + the forced-battle pending seam (the guardian
# precedent, overworld_mons_sim.gd:129-135) through the runtime's documented internal
# dicts — there is NO public spawn API, and adding one would rewrite a Phase-6 file.
func _ensure_ruins_guardian(player_tile: Vector2i) -> void:
	if _overworld_mons == null or not bool(_overworld_mons.active):
		return # activation gate: non-opt-in smoke scenarios stay entity-free (baseline protection)
	for landmark in Landmarks.landmarks_in_world(_world_seed(), _chain()):
		if str(landmark["landmark_id"]) == Landmarks.RUINS_ID:
			_spawn_ruins_guardian(landmark["footprint"], player_tile)
	for inst in LandmarkScatter.instances_in_window(_world_seed(), player_tile, GUARDIAN_SCAN_TILES): # slice 3: a scattered ruins gets its guardian too
		if str(inst.get("landmark_id", "")) == Landmarks.RUINS_ID:
			_spawn_ruins_guardian(inst["footprint"], player_tile)

func _spawn_ruins_guardian(footprint: Rect2i, player_tile: Vector2i) -> void:
	var tile: Vector2i = footprint.position + UNDERGROUND_GUARD_LOCAL
	var cell := OverworldMons.cell_for_tile(tile)
	if not OverworldMons.in_spawn_band(OverworldMons.cell_for_tile(player_tile), cell):
		return # the same band the sim's distance despawn rides; re-injected on re-entry
	var id := DUSCLOPS_ID % [cell.x, cell.y]
	var entities: Variant = _overworld_mons.get("_entities")
	var removed: Variant = _overworld_mons.get("_removed")
	if not (entities is Dictionary) or not (removed is Dictionary) or (entities as Dictionary).has(id) or (removed as Dictionary).has(id):
		return # KO/catch removal is PERMANENT per world (stationary rematch rule, :284/:288)
	var sim: Variant = _overworld_mons.get("_sim")
	if sim == null or not sim.has_method("new_mon"):
		return
	var level := OverworldMons.guardian_level_for(_world_seed(), cell, sim.ring_of(cell))
	(entities as Dictionary)[id] = sim.new_mon(id, OverworldMons.CLASS_STATIONARY, 0, cell, Landmarks.RUINS_UNDERGROUND_SPECIES, tile, level, OverworldMons.DISPOSITION_AGGRESSIVE)
	_emit("landmark_entity_spawned", {"species_id": Landmarks.RUINS_UNDERGROUND_SPECIES, "tile": _t(tile), "landmark_id": Landmarks.RUINS_ID, "disposition": OverworldMons.DISPOSITION_AGGRESSIVE})

# --- Seam + mansion helpers (instance-keyed, slice 3) ---------------------------------
# The frozen seam stays (whole-dict landmark_state_for/set_landmark_state); the KEYS are
# per-instance "pkmn_mansion@ax,ay" off the footprint anchor, so every mansion instance
# carries independent puzzle state. The instance is resolved from the stamped logic.
func _mansion_state(instance_key: String) -> Dictionary:
	if _session == null:
		return Landmarks.default_mansion_state()
	var all: Dictionary = _session.landmark_state_for(_chain()) # FROZEN SEAM — never the keying
	var raw: Variant = all.get(instance_key, {})
	return Landmarks.mansion_state_from(raw if raw is Dictionary else {})

func _write_mansion(instance_key: String, next_state: Dictionary) -> void:
	var all: Dictionary = _session.landmark_state_for(_chain())
	all[instance_key] = next_state
	_session.set_landmark_state(_chain(), all) # FROZEN SEAM — merge by construction (never clobbers a sibling instance)

func _take_key(faced: Vector2i) -> Dictionary:
	_session.add_item(Landmarks.MANSION_KEY_ID, 1)
	return {"handled": true, "refresh": _door_tiles(faced), "message": "A brass key lies beside the journal. You take it."} # refresh -> route_landmark persists the pickup immediately (a reload before the door arm no longer drops the bagged key)

# The mansion instance owning `tile` ({} when none): the stamped instance key parses to the anchor (the additive landmark_instance the consults carry).
func _mansion_at(tile: Vector2i) -> Dictionary:
	var logic: Dictionary = tile_logic_for_active(tile, {})
	if str(logic.get("landmark_id", "")) != Landmarks.MANSION_ID:
		return {}
	var parsed := ContentScatter.parse_instance_key(str(logic.get("landmark_instance", "")))
	if parsed.is_empty():
		return {}
	return {"anchor": parsed["anchor"], "key": str(logic.get("landmark_instance", "")), "origin": (parsed["anchor"] as Vector2i) - Landmarks.MANSION_SIZE / 2}

func _door_tiles(faced: Vector2i) -> Array: # world tiles of the faced mansion's doors (puzzle flips -> view refresh)
	var mansion := _mansion_at(faced)
	if mansion.is_empty():
		return []
	return [mansion["origin"] + ROOM_DOOR_LOCAL, mansion["origin"] + SEWER_DOOR_LOCAL]

func _is_mansion_local(faced: Vector2i, local: Vector2i) -> bool:
	var mansion := _mansion_at(faced)
	return not mansion.is_empty() and mansion["origin"] + local == faced

func _chain() -> Vector2i: return Vector2i.ZERO # infinite-world slice: a single seamless origin plane — chain frozen at (0,0); nothing below branches on it.
func _in_dungeon() -> bool: return _session != null and str(_session.active_area) != "" # the dungeon gate, session-direct (the dungeon_runtime.in_dungeon predicate)
func _world_seed() -> int: return int(_session.world_seed) if _session != null else 0

func _emit(event_name: String, payload: Dictionary) -> void:
	if _trace != null:
		_trace.emit_event(event_name, "LandmarkRuntime", payload) # owning source (spec § Smoke: the frozen trace payloads)

func _warn(message: String, payload: Dictionary) -> void:
	if _trace != null:
		_trace.warning("LandmarkRuntime", message, payload)

func _t(tile: Vector2i) -> Array:
	return [tile.x, tile.y]
