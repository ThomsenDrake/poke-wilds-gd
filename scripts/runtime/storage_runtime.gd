extends RefCounted

# Storage Box runtime (Phase 3; spec: docs/product-specs/storage-and-party.md):
# INDEPENDENT per-placement Pokemon containers — faithful, NO shared PC
# (buildings-scrape.md:290-294: "the contents of the box are not shared with
# other built boxes"; pokewilds-build.md:37: "not connected to other storage
# chests"). Box identity IS its tile: contents ride the placement entry itself
# under the additive "contents" key (the campfire "lit" precedent), so two
# boxes can never share by construction and demolishing a box removes entry +
# contents atomically. Overflow captures do NOT route here — they stay on the
# campsite hold (battle_runtime); boxes are MANUAL walk-to containers.
#
# Every result is {ok, reason, message, ...}; every refusal is traced via
# storage_refused, never silent. RELEASE is permanent removal: the original
# "drops" a released mon into the world (lchan-review.md:45) but the port has
# no overworld-mon entities yet, so the UI layer confirm-gates before calling
# release_*; this runtime executes confirm-agnostic, exactly like new_game.

const Structures := preload("res://scripts/domain/structures.gd")
const FieldMoves := preload("res://scripts/domain/field_moves.gd")

var _session = null
var _trace = null
var _world_gen = null
var _get_species: Callable = Callable()


func setup(session_state, trace_logger, world_generator, get_species: Callable) -> void:
	_session = session_state
	_trace = trace_logger
	_world_gen = world_generator
	_get_species = get_species


# Opens the box on the tile for the UI (traces box_opened); refuses no_box.
func open_box(tile: Vector2i) -> Dictionary:
	var entry := _box_entry(tile)
	if entry.is_empty():
		return _refuse("open", tile, "no_box", "")
	var contents := Structures.box_contents(entry)
	_emit("box_opened", {"tile": _tile_payload(tile), "count": contents.size()})
	return {"ok": true, "reason": "", "tile": tile, "contents": contents, "count": contents.size(),
		"message": ""}


# The box's mons (deep copy, safe for UI); [] when the tile carries no box.
func box_snapshot(tile: Vector2i) -> Array:
	return Structures.box_contents(_box_entry(tile))


# The first storage box adjacent to `center` (deterministic UP/DOWN/LEFT/RIGHT
# scan) as {"found": bool, "tile": Vector2i} — the party-screen DEPOSIT target
# ("boxes kept outside / right next to an entrance", house-building-scrape.md:261,
# mechanized). `found` is the sentinel: a box built at world tile (0,0) is a real
# box, so no tile value may double as "no box" (the old Vector2i.ZERO return
# shadowed the origin box on every nearest path).
func box_tile_near(center: Vector2i) -> Dictionary:
	var placements: Dictionary = _world_gen.placements_for_save()
	for direction in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		var tile: Vector2i = center + direction
		var entry: Variant = placements.get("%d,%d" % [tile.x, tile.y], {})
		if entry is Dictionary and Structures.is_storage(str((entry as Dictionary).get("structure_id", ""))):
			return {"found": true, "tile": tile}
	return {"found": false, "tile": Vector2i.ZERO}


# Convenience for context callables: the box beside the player ({found, tile}).
func nearest_box_tile() -> Dictionary:
	return box_tile_near(_session.player_tile)


# Party -> box. Refusals: no_box, no_such_mon, last_party_member, and the
# dynamic witness guard (would_strand_demolition) — never silent.
func deposit(tile: Vector2i, party_index: int) -> Dictionary:
	var entry := _live_entry(tile)
	if entry.is_empty():
		return _refuse("deposit", tile, "no_box", "")
	if party_index < 0 or party_index >= _session.party.size():
		return _refuse("deposit", tile, "no_such_mon", "")
	if _session.party.size() == 1:
		return _refuse("deposit", tile, "last_party_member", _species_at(party_index))
	var mon: Dictionary = _session.party[party_index]
	if bool(mon.get("is_egg", false)): # Phase 5: eggs are carried, never boxed
		return _refuse("deposit", tile, "eggs_stay_with_you", "EGG")
	var stranded := _stranded_move(party_index)
	if not stranded.is_empty():
		return _refuse_strand("deposit", tile, mon, stranded)
	_session.party.remove_at(party_index)
	var contents := Structures.box_contents(entry)
	contents.append(mon)
	_write_contents(entry, contents)
	_emit("mon_deposited", {"tile": _tile_payload(tile), "species_id": str(mon.get("species_id", "")),
		"name": str(mon.get("name", "")), "level": int(mon.get("level", 1)),
		"party_size": _session.party.size(), "box_count": contents.size()})
	return {"ok": true, "reason": "", "tile": tile, "species_id": str(mon.get("species_id", "")),
		"message": "%s was moved to the storage box." % str(mon.get("name", "Pokemon"))}


# Party -> the box adjacent to the player (the party-screen DEPOSIT path).
func deposit_to_nearest(party_index: int) -> Dictionary:
	var near := nearest_box_tile()
	if not bool(near.get("found", false)):
		return _refuse("deposit", _session.player_tile, "no_box", "")
	var tile: Vector2i = near.get("tile", Vector2i.ZERO)
	return deposit(tile, party_index)


# Box -> party. Refusals: no_box, no_such_mon, party_full (party cap stays 6).
func withdraw(tile: Vector2i, content_index: int) -> Dictionary:
	var entry := _live_entry(tile)
	if entry.is_empty():
		return _refuse("withdraw", tile, "no_box", "")
	var contents := Structures.box_contents(entry)
	if content_index < 0 or content_index >= contents.size():
		return _refuse("withdraw", tile, "no_such_mon", "")
	if _session.party.size() >= 6:
		return _refuse("withdraw", tile, "party_full", str(contents[content_index].get("species_id", "")))
	var mon: Dictionary = contents[content_index]
	contents.remove_at(content_index)
	_write_contents(entry, contents)
	_session.party.append(mon)
	_emit("mon_withdrawn", {"tile": _tile_payload(tile), "species_id": str(mon.get("species_id", "")),
		"name": str(mon.get("name", "")), "level": int(mon.get("level", 1)),
		"party_size": _session.party.size(), "box_count": contents.size()})
	return {"ok": true, "reason": "", "tile": tile, "species_id": str(mon.get("species_id", "")),
		"message": "%s rejoined the party." % str(mon.get("name", "Pokemon"))}


# Permanently removes a boxed mon (confirm lives in the UI layer). Release FROM
# a box never changes the party pool, so the witness guard does not apply.
func release_from_box(tile: Vector2i, content_index: int) -> Dictionary:
	var entry := _live_entry(tile)
	if entry.is_empty():
		return _refuse("release", tile, "no_box", "")
	var contents := Structures.box_contents(entry)
	if content_index < 0 or content_index >= contents.size():
		return _refuse("release", tile, "no_such_mon", "")
	var mon: Dictionary = contents[content_index]
	contents.remove_at(content_index)
	_write_contents(entry, contents)
	_emit("mon_released", {"source": "box", "tile": _tile_payload(tile),
		"species_id": str(mon.get("species_id", "")), "name": str(mon.get("name", "")),
		"level": int(mon.get("level", 1))})
	return {"ok": true, "reason": "", "tile": tile, "species_id": str(mon.get("species_id", "")),
		"message": "%s was released. It's gone for good." % str(mon.get("name", "Pokemon"))}


# Permanently removes a party mon (confirm lives in the UI layer); the witness
# guard refuses to strand a demolition move the standing structures need.
func release_from_party(party_index: int) -> Dictionary:
	if party_index < 0 or party_index >= _session.party.size():
		return _refuse("release", _session.player_tile, "no_such_mon", "")
	var mon: Dictionary = _session.party[party_index]
	if bool(mon.get("is_egg", false)): # Phase 5: eggs are never released (they are unborn mons)
		return _refuse("release", _session.player_tile, "eggs_stay_with_you", "EGG")
	var stranded := _stranded_move(party_index)
	if not stranded.is_empty():
		return _refuse_strand("release", _session.player_tile, mon, stranded)
	_session.party.remove_at(party_index)
	_emit("mon_released", {"source": "party", "tile": _tile_payload(_session.player_tile),
		"species_id": str(mon.get("species_id", "")), "name": str(mon.get("name", "")),
		"level": int(mon.get("level", 1))})
	return {"ok": true, "reason": "", "tile": _session.player_tile,
		"species_id": str(mon.get("species_id", "")),
		"message": "%s was released. It's gone for good." % str(mon.get("name", "Pokemon"))}


# --- The demolition-witness guard extension (load-bearing; the building spec's
# escape invariant held while "mons never leave the party" — boxes change that) --

# Demolish moves the standing structures require (cut and/or smash): per placed
# tile, Structures.demolish_move_for over the tile's live biome. Empty (guard
# dormant) when nothing is placed. O(placements) per deposit/release is
# negligible — both are rare, player-driven actions.
func required_witness_moves() -> Array:
	var required := {}
	var placements: Dictionary = _world_gen.placements_for_save()
	for key in placements.keys():
		var parts := str(key).split(",")
		if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
			continue
		var tile := Vector2i(parts[0].to_int(), parts[1].to_int())
		var structure_id := str((placements[key] as Dictionary).get("structure_id", ""))
		var biome := str(_world_gen.get_tile_logic(tile).get("biome", ""))
		required[Structures.demolish_move_for(structure_id, biome)] = true
	return required.keys()


# The required move removing party member `party_index` would strand ("" = none):
# the party carries move M but the party without that mon does not. The PARTY
# pool counts, never box contents — the party travels with the player, while a
# box may be sealed away behind the player's own wall ring (conservative).
func _stranded_move(party_index: int) -> String:
	for move_id in required_witness_moves():
		if _party_can(str(move_id), -1) and not _party_can(str(move_id), party_index):
			return str(move_id)
	return ""


# Any party member (or a specific one, skipping `skip_index`) performs the move.
func _party_can(move_id: String, skip_index: int) -> bool:
	for i in range(_session.party.size()):
		if i == skip_index:
			continue
		var mon = _session.party[i]
		if mon is Dictionary and FieldMoves.can_perform(mon, move_id, _get_species):
			return true
	return false


# --- Internals ----------------------------------------------------------------

# Read path: the public save-shape view (duplicate), filtered to storage boxes.
func _box_entry(tile: Vector2i) -> Dictionary:
	var entry: Variant = _world_gen.placements_for_save().get("%d,%d" % [tile.x, tile.y], {})
	if entry is Dictionary and Structures.is_storage(str((entry as Dictionary).get("structure_id", ""))):
		return entry
	return {}


# Write path: the documented reach into the generator's live placement map that
# field_action_router's campfire "lit" toggle already uses (world_generator is
# at its line ceiling, no room for a mutator; tech debt promotes this to typed
# accessors). The box IS the entry: mutating "contents" in place keeps box +
# contents atomic — demolition erases the entry and its contents in one remove.
func _live_entry(tile: Vector2i) -> Dictionary:
	var placements: Variant = (_world_gen as Object).get("_placements")
	if not (placements is Dictionary) or not (placements as Dictionary).has(tile):
		return {}
	var entry: Variant = (placements as Dictionary)[tile]
	if entry is Dictionary and Structures.is_storage(str((entry as Dictionary).get("structure_id", ""))):
		return entry
	return {}


# Absent "contents" == empty box: an emptied box drops the key again so v3-era
# saves and v4 empty-box saves stay byte-identical in shape.
func _write_contents(entry: Dictionary, contents: Array) -> void:
	if contents.is_empty():
		entry.erase("contents")
	else:
		entry["contents"] = contents


func _species_at(party_index: int) -> String:
	return str((_session.party[party_index] as Dictionary).get("species_id", ""))


func _refuse_strand(action: String, tile: Vector2i, mon: Dictionary, move_id: String) -> Dictionary:
	_emit("storage_refused", {"action": action, "tile": _tile_payload(tile),
		"reason": "would_strand_demolition", "species_id": str(mon.get("species_id", ""))})
	return {"ok": false, "reason": "would_strand_demolition", "tile": tile,
		"message": "You can't let %s go — nothing left in your party can %s, and you have structures standing." % [str(mon.get("name", "Pokemon")), move_id.to_upper()]}


func _refuse(action: String, tile: Vector2i, reason: String, species_id: String) -> Dictionary:
	_emit("storage_refused", {"action": action, "tile": _tile_payload(tile), "reason": reason, "species_id": species_id})
	return {"ok": false, "reason": reason, "tile": tile, "message": _refusal_message(reason)}


func _refusal_message(reason: String) -> String:
	match reason:
		"no_box":
			return "There is no storage box there."
		"no_such_mon":
			return "There is no Pokemon there."
		"last_party_member":
			return "You can't deposit your last Pokemon."
		"party_full":
			return "Your party is already full."
		"eggs_stay_with_you":
			return "You keep the Egg with you."
	return "That can't be done."


func _tile_payload(tile: Vector2i) -> Array:
	return [tile.x, tile.y]


func _emit(event_name: String, payload: Dictionary) -> void:
	_trace.emit_event(event_name, "StorageRuntime", payload)
