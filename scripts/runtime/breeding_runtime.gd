extends RefCounted

# Breeding + egg runtime (Phase 5; spec: docs/product-specs/breeding-shinies-drops-fishing.md). PENS = Phase-1 fences
# (Breeding.detect_pens flood; door-in-fence stays walkable — an open pen is no pen, faithful). Mons have no overworld entities yet (Phase 6), so penned
# mons ride an abstract PASTURE per pen anchor under the v4 ADDITIVE session key "pastures",
# held BY REFERENCE: _pastures IS _session.pastures — habitat_runtime reads/writes the same
# dicts in place, so its daily +10 happiness reaches the 220 lay gate with NO save roundtrip
# (tick + _pasture self-heal the stale binding new_game's fresh dict leaves); eggs render via
# ground_egg_at. FAITHFUL (wiki-breeding.md): exactly ONE compatible happy pair per pen (a
# third breaks attraction); the mother leaves an egg on a pen tile (EGG_GROUND_CAP, self-trap);
# child species = the MOTHER's (non-Ditto parent), gender + the FATHER's egg moves + shiny roll
# at LAY time, VISIBLE pre-hatch; hatching is step-based IN THE PARTY. LAY GATE: the drops
# comfort model (HabitatDrops tags over interior + ring, per parent, AND'd — drops-comfortable
# ⟺ lay-gate passes) AND both mons happy >= BREED_HAPPY_THRESHOLD. DETERMINISM: rolls ride the INJECTED shared rng
# (seed_for_smoke pins it); the ring scan consumes none (pure tile reads); shiny_rolled on EVERY egg creation; hatch SFX windowed-only (egg_noise1.ogg).

const Breeding := preload("res://scripts/domain/breeding.gd")
const HabitatDrops := preload("res://scripts/domain/habitat_drops.gd")

const PEN_FLOOD_BUDGET := 256 # enclosed pens flood far under; open regions blow the budget
const EGG_GROUND_CAP := 7 # faithful 7-egg cap before the producer self-traps
const BREED_HAPPY_THRESHOLD := 220 # HAPPINESS_EVOLUTION_THRESHOLD doubles as "happy"
const LAY_CHECK_STEPS := 120 # the invisible-countdown cadence (rate-limited scan)
const LAY_CHANCE := 0.5 # seeded roll per cadence (Eevee-farm anchor: ~6 eggs / <15 min)
const HATCH_SFX_PATH := "res://pokewilds/sounds/egg_noise1.ogg"

var _session = null
var _catalog = null
var _rules = null
var _trace = null
var _world_gen = null
var _rng = null # injected shared rng — NEVER a private seed (determinism seam)
var _emit_tile: Callable = Callable() # world_overridden (ground-egg re-render)
var _sfx_parent: Node = null
var _pastures: Dictionary = {} # the SAME object as _session.pastures (reference identity; self-healed)
var _regions: Dictionary = {} # "x,y" anchor -> Array[Vector2i] (cached flood)
var _regions_dirty := true
var _ground_index: Dictionary = {} # "x,y" tile -> {"is_shiny": bool}
var _warned_pens: Dictionary = {} # pen key -> true (one not_breedable warning each)
func setup(session_state, catalog, pokemon_rules, trace_logger, world_generator, rng, emit_tile: Callable, sfx_parent: Node = null) -> void:
	_session = session_state; _catalog = catalog; _rules = pokemon_rules
	_trace = trace_logger; _world_gen = world_generator; _rng = rng
	_emit_tile = emit_tile; _sfx_parent = sfx_parent; _pastures = _session.pastures

func note_structures_changed() -> void: # build/demolish flips geometry; harvest never does
	_regions_dirty = true
	_warned_pens.clear()
	apply_save_state(save_state()) # a broken ring strands its mons until load otherwise — run the no-loss relocation pass LIVE
func pen_tiles(pen_key: String) -> Array: return _detect_regions().get(pen_key, [])

# First pen with an interior tile beside `center` ({found, tile}); the deposit gate, mirroring box_tile_near's found flag (never a tile sentinel — pens at (0,0) are real).
func pen_tile_near(center: Vector2i) -> Dictionary:
	for pen_key in _detect_regions().keys():
		for tile in _detect_regions()[pen_key]:
			if absi(tile.x - center.x) + absi(tile.y - center.y) == 1:
				return {"found": true, "tile": tile}
	return {"found": false, "tile": Vector2i.ZERO}

# Party -> pen (party-screen DEPOSIT fallback when no box is near). Refusals: no_pen, no_such_mon,
# last_party_member, eggs_stay_with_you. NO demolition-witness guard (unlike boxes): a penned mon is always withdrawable via the fence Z, so never stranded.
func deposit_to_nearest_pen(party_index: int) -> Dictionary:
	var near := pen_tile_near(_session.player_tile)
	if not bool(near.get("found", false)):
		return _refuse("deposit", "no_pen", "There is no pen here.")
	if party_index < 0 or party_index >= _session.party.size():
		return _refuse("deposit", "no_such_mon", "There is no Pokemon there.")
	if _session.party.size() == 1:
		return _refuse("deposit", "last_party_member", "You can't pen your last Pokemon.")
	var mon: Dictionary = _session.party[party_index]
	if bool(mon.get("is_egg", false)):
		return _refuse("deposit", "eggs_stay_with_you", "You keep the Egg with you.")
	var pen_key := _pen_key_for_tile(near.get("tile", Vector2i.ZERO))
	if pen_key.is_empty():
		return _refuse("deposit", "no_pen", "There is no pen here.")
	_session.party.remove_at(party_index)
	_pasture(pen_key)["mons"].append(mon)
	_emit("mon_penned", {"pen": pen_key, "species_id": str(mon.get("species_id", "")), "name": str(mon.get("name", "")), "level": int(mon.get("level", 1)), "party_size": _session.party.size(), "pen_count": _pasture(pen_key)["mons"].size()})
	return {"ok": true, "reason": "", "pen": pen_key, "species_id": str(mon.get("species_id", "")), "message": "%s was released into the pen." % str(mon.get("name", "Pokemon"))}

# Faced-tile Z through a fence: pick up a ground egg (priority), else withdraw the most recently penned mon, else
# report the pen empty. {} when no pen interior lies beyond the faced tile (the router falls through to harvest/build).
func interact(player_tile: Vector2i, faced_tile: Vector2i) -> Dictionary:
	var direction := faced_tile - player_tile
	if absi(direction.x) + absi(direction.y) != 1:
		return {}
	var pen_key := _pen_key_for_tile(faced_tile + direction)
	if pen_key.is_empty():
		return {}
	var entry: Variant = _pastures.get(pen_key, {}) # read WITHOUT creating: a quiet pen never touches the shared store
	var eggs: Variant = (entry as Dictionary).get("eggs", []) if entry is Dictionary else []
	if eggs is Array and not (eggs as Array).is_empty():
		return _pick_up_egg(pen_key, 0)
	var mons: Variant = (entry as Dictionary).get("mons", []) if entry is Dictionary else []
	if mons is Array and not (mons as Array).is_empty():
		return _withdraw(pen_key, (mons as Array).size() - 1)
	return {"ok": true, "reason": "", "message": "The pen is quiet."}

func ground_egg_at(tile: Vector2i) -> Dictionary: # ground eggs for world_view
	var entry: Variant = _ground_index.get("%d,%d" % [tile.x, tile.y], null)
	if entry is Dictionary:
		return {"has_egg": true, "is_shiny": bool((entry as Dictionary).get("is_shiny", false))}
	return {"has_egg": false, "is_shiny": false}

func pasture_snapshot() -> Dictionary: # deep copy for audits — the LIVE store is _session.pastures itself
	return _pastures.duplicate(true)

func tick() -> void: # per player step (game_runtime.note_player_step)
	if not is_same(_pastures, _session.pastures): # self-heal: new_game/load assign a fresh session dict
		_pastures = _session.pastures
	_tick_party_eggs()
	if int(_session.total_steps) % LAY_CHECK_STEPS == 0:
		_tick_pen_laying()

# Save/load: normalize onto the session dict (the SHARED store) and REBIND _pastures. A pen whose enclosure no longer floods loses its eggs but NEVER its mons — campsite hold (never-lose), LIVE on demolition too (note_structures_changed).
func apply_save_state(raw: Variant) -> void:
	var normalized: Dictionary = {}
	if raw is Dictionary:
		for key in (raw as Dictionary).keys():
			var pasture := _normalize_pasture((raw as Dictionary)[key])
			if not pasture["mons"].is_empty() or not pasture["eggs"].is_empty():
				normalized[str(key)] = pasture
	_session.pastures = normalized
	for pen_key in _session.pastures.keys():
		if _detect_regions().has(pen_key):
			continue
		var pasture: Dictionary = _session.pastures[pen_key]
		for mon in pasture["mons"]:
			_session.campsite_pokemon.append(mon)
		_trace.warning("BreedingRuntime", "A pen no longer encloses; mons relocated to the campsite.",
			{"pen": pen_key, "mons_relocated": pasture["mons"].size(), "eggs_lost": pasture["eggs"].size()})
		_session.pastures.erase(pen_key)
	_pastures = _session.pastures # rebind: normalization just replaced the session dict
	_rebuild_ground_index()
func save_state() -> Dictionary:
	return _pastures.duplicate(true)

# --- Internals -------------------------------------------------------------------

func _tick_party_eggs() -> void:
	for i in range(_session.party.size()):
		var mon = _session.party[i]
		if not (mon is Dictionary) or not bool((mon as Dictionary).get("is_egg", false)):
			continue
		var payload: Dictionary = (mon as Dictionary).get("egg", {})
		var remaining := maxi(0, int(payload.get("steps_to_hatch", 1)) - 1)
		payload["steps_to_hatch"] = remaining
		if remaining > 0:
			continue
		var child_entry: Dictionary = _catalog.get_species(str(payload.get("species_id", "")))
		if child_entry.is_empty():
			_trace.warning("BreedingRuntime", "Egg species missing from the catalog; hatch skipped.", {"species_id": str(payload.get("species_id", ""))})
			continue
		var hatched := Breeding.hatch_egg(mon, child_entry, Callable(_catalog, "get_move"), _rng)
		if hatched.is_empty():
			continue
		_session.party[i] = hatched
		_play_hatch_sfx()
		_emit("egg_hatched", {"species_id": str(hatched.get("species_id", "")), "name": str(hatched.get("name", "")), "level": int(hatched.get("level", 1)),
			"gender": str(hatched.get("gender", "")), "is_shiny": bool(hatched.get("is_shiny", false)), "egg_moves": payload.get("moves", [])})
func _tick_pen_laying() -> void:
	var get_species := Callable(_catalog, "get_species")
	for pen_key in _detect_regions().keys():
		var entry: Variant = _pastures.get(pen_key, {}) # read WITHOUT creating: scanning must not pollute the shared store
		var mons: Variant = (entry as Dictionary).get("mons", []) if entry is Dictionary else []
		var eggs: Variant = (entry as Dictionary).get("eggs", []) if entry is Dictionary else []
		if not (mons is Array) or not (eggs is Array) or (mons as Array).size() < 2 or (eggs as Array).size() >= EGG_GROUND_CAP:
			continue
		var pair := Breeding.find_pair(mons as Array, get_species)
		if pair.is_empty():
			if not _warned_pens.has(pen_key) and _has_unbreedable(mons as Array):
				_warned_pens[pen_key] = true
				_trace.warning("BreedingRuntime", "Pen holds Pokemon that cannot breed.", {"reason": "not_breedable", "pen": pen_key})
			continue # no pair — or more than one (a third compatible mon breaks attraction)
		var mother: Dictionary = (mons as Array)[int(pair["mother"])]
		var father: Dictionary = (mons as Array)[int(pair["father"])]
		if int(mother.get("happiness", 0)) < BREED_HAPPY_THRESHOLD or int(father.get("happiness", 0)) < BREED_HAPPY_THRESHOLD:
			continue
		var tiles: Array = _detect_regions()[pen_key]
		var tags := HabitatDrops.pen_habitat_tags(tiles, Callable(_world_gen, "get_tile_logic"))
		if not _types_satisfied(mother, tags) or not _types_satisfied(father, tags):
			continue
		if _rng.randf() >= LAY_CHANCE:
			continue
		_lay_egg(pen_key, mother, father, tiles)
func _lay_egg(pen_key: String, mother: Dictionary, father: Dictionary, tiles: Array) -> void:
	var occupied := {}
	for egg_entry in _pasture(pen_key)["eggs"]:
		var egg_tile := _egg_tile(egg_entry)
		occupied["%d,%d" % [egg_tile.x, egg_tile.y]] = true
	var free_tiles: Array = []
	for tile in tiles:
		if not occupied.has("%d,%d" % [tile.x, tile.y]):
			free_tiles.append(tile)
	if free_tiles.is_empty():
		return
	var mother_entry: Dictionary = _catalog.get_species(str(mother.get("species_id", "")))
	var father_entry: Dictionary = _catalog.get_species(str(father.get("species_id", "")))
	var child_entry := father_entry if Breeding.is_ditto(mother_entry) else mother_entry
	if child_entry.is_empty():
		return
	var lay_tile: Vector2i = free_tiles[_rng.randi_range(0, free_tiles.size() - 1)]
	var egg := Breeding.build_egg(mother, father, child_entry, Callable(_catalog, "get_move"), _rng, str(_session.total_steps))
	var payload: Dictionary = egg.get("egg", {})
	_emit("shiny_rolled", {"species_id": str(payload.get("species_id", "")), "is_shiny": bool(egg.get("is_shiny", false)), "odds": Breeding.shiny_odds(), "origin": "egg"}) # EVERY creation — odds provable both ways
	_pasture(pen_key)["eggs"].append({"tile": [lay_tile.x, lay_tile.y], "egg": egg})
	_ground_index["%d,%d" % [lay_tile.x, lay_tile.y]] = {"is_shiny": bool(egg.get("is_shiny", false))}
	if _emit_tile.is_valid():
		_emit_tile.call(lay_tile)
	_emit("egg_laid", {"tile": [lay_tile.x, lay_tile.y], "pen": pen_key, "mother_species_id": str(mother.get("species_id", "")),
		"father_species_id": str(father.get("species_id", "")), "species_id": str(payload.get("species_id", "")),
		"gender": str(payload.get("gender", "")), "is_shiny": bool(egg.get("is_shiny", false)),
		"steps_to_hatch": int(payload.get("steps_to_hatch", 0)), "eggs_in_pen": _pasture(pen_key)["eggs"].size()})
func _pick_up_egg(pen_key: String, egg_index: int) -> Dictionary:
	if _session.party.size() >= 6:
		return _refuse("egg_pickup", "party_full", "Your party is full.")
	var pasture := _pasture(pen_key)
	var egg: Dictionary = (pasture["eggs"][egg_index] as Dictionary).get("egg", {})
	var tile := _egg_tile(pasture["eggs"][egg_index])
	pasture["eggs"].remove_at(egg_index)
	_ground_index.erase("%d,%d" % [tile.x, tile.y])
	_session.party.append(egg)
	if _emit_tile.is_valid():
		_emit_tile.call(tile)
	var payload: Dictionary = egg.get("egg", {})
	_emit("egg_picked_up", {"pen": pen_key, "species_id": str(payload.get("species_id", "")), "tile": [tile.x, tile.y], "is_shiny": bool(egg.get("is_shiny", false)), "party_size": _session.party.size()})
	return {"ok": true, "reason": "", "message": "You picked up the Egg. It feels warm."}
func _withdraw(pen_key: String, mon_index: int) -> Dictionary:
	if _session.party.size() >= 6:
		return _refuse("withdraw", "party_full", "Your party is full.")
	var pasture := _pasture(pen_key)
	var mon: Dictionary = pasture["mons"][mon_index]
	pasture["mons"].remove_at(mon_index)
	if pasture["mons"].is_empty() and pasture["eggs"].is_empty(): # symmetric with habitat_runtime's shared-store erase
		_pastures.erase(pen_key)
	_session.party.append(mon)
	_emit("mon_withdrawn", {"source": "pen", "pen": pen_key, "species_id": str(mon.get("species_id", "")), "name": str(mon.get("name", "")), "level": int(mon.get("level", 1)), "party_size": _session.party.size(), "pen_count": pasture["mons"].size()})
	return {"ok": true, "reason": "", "message": "%s hopped back into your party." % str(mon.get("name", "Pokemon"))}
func _detect_regions() -> Dictionary:
	if _regions_dirty:
		_regions = Breeding.detect_pens(_world_gen.placements_for_save(), Callable(_world_gen, "get_tile_logic"), PEN_FLOOD_BUDGET)
		_regions_dirty = false
	return _regions
func _normalize_pasture(raw: Variant) -> Dictionary:
	var pasture := {"mons": [], "eggs": []}
	if not (raw is Dictionary):
		return pasture
	var raw_mons: Variant = (raw as Dictionary).get("mons", [])
	if raw_mons is Array:
		for mon in raw_mons:
			if mon is Dictionary and not (mon as Dictionary).is_empty():
				pasture["mons"].append(_rules.normalize_loaded_mon(mon))
	var raw_eggs: Variant = (raw as Dictionary).get("eggs", [])
	if raw_eggs is Array:
		for egg_variant in raw_eggs:
			if egg_variant is not Dictionary:
				continue
			var egg: Variant = (egg_variant as Dictionary).get("egg", {})
			if egg is Dictionary and bool((egg as Dictionary).get("is_egg", false)):
				var tile := _egg_tile(egg_variant)
				pasture["eggs"].append({"tile": [tile.x, tile.y], "egg": egg})
	return pasture
func _rebuild_ground_index() -> void:
	_ground_index = {}
	for pen_key in _pastures.keys():
		for egg_entry in (_pastures[pen_key] as Dictionary)["eggs"]:
			var tile := _egg_tile(egg_entry)
			var egg: Dictionary = (egg_entry as Dictionary).get("egg", {})
			_ground_index["%d,%d" % [tile.x, tile.y]] = {"is_shiny": bool(egg.get("is_shiny", false))}

# One-shot hatch SFX (attack_animator pattern): windowed only — headless skips the player.
func _play_hatch_sfx() -> void:
	# DisplayServer.get_name() is the reliable headless test (OS.has_feature("headless") reads false under --headless in this engine, leaking the player).
	if _sfx_parent == null or DisplayServer.get_name() == "headless" or not ResourceLoader.exists(HATCH_SFX_PATH):
		return
	var stream = load(HATCH_SFX_PATH)
	if stream is not AudioStream:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	_sfx_parent.add_child(player)
	player.play()
	player.finished.connect(player.queue_free)
func _has_unbreedable(mons: Array) -> bool:
	for mon in mons:
		if mon is Dictionary and Breeding.is_unbreedable(_catalog.get_species(str((mon as Dictionary).get("species_id", "")))):
			return true
	return false
func _types_satisfied(mon: Dictionary, tags: Dictionary) -> bool: # one parent's lay-gate verdict
	var species_id := str(mon.get("species_id", ""))
	var entry: Dictionary = _catalog.get_species(species_id)
	return HabitatDrops.types_satisfied(entry.get("types", PackedStringArray()), species_id, tags)
func _pasture(pen_key: String) -> Dictionary: # SHARED store: add missing keys, never clobber habitat's
	if not is_same(_pastures, _session.pastures): # heal a deposit that beat the first tick after new_game
		_pastures = _session.pastures
	if not _pastures.has(pen_key):
		_pastures[pen_key] = {}
	var pasture: Dictionary = _pastures[pen_key]
	if not pasture.has("mons"): # habitat's deposit shape has no "eggs"; breeding's has no "anchor"
		pasture["mons"] = []
	if not pasture.has("eggs"):
		pasture["eggs"] = []
	return pasture
func _pen_key_for_tile(tile: Vector2i) -> String:
	var regions := _detect_regions()
	for pen_key in regions.keys():
		if (regions[pen_key] as Array).has(tile):
			return str(pen_key)
	return ""
func _egg_tile(egg_entry: Dictionary) -> Vector2i:
	var tile: Variant = egg_entry.get("tile", [0, 0])
	if tile is Array and (tile as Array).size() == 2:
		return Vector2i(int(tile[0]), int(tile[1]))
	return Vector2i.ZERO
func _refuse(action: String, reason: String, message: String) -> Dictionary:
	_emit("breeding_refused", {"action": action, "reason": reason})
	return {"ok": false, "reason": reason, "message": message}
func _emit(event_name: String, payload: Dictionary) -> void:
	if _trace != null:
		_trace.emit_event(event_name, "BreedingRuntime", payload)
