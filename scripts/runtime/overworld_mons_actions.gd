extends RefCounted

# Phase 6 overworld mons — the PLAYER-ACTION surface, EXTRACTED from overworld_mons_runtime.gd
# (both at the 320 runtime budget; the runtime keeps the entity store, the forced-battle
# PENDING seam, note_battle_outcome and every store-level trace — this owns Attack/Charm via
# the Phase-4 hooks, dialogue recruitment, the wild-egg TAKE/Attack binary :248, and the
# interact-provocation memory). It reaches the runtime's store/seam through the injected
# WEAKREF back-reference (the overworld_mons_sim precedent — the subsystem's internal seam,
# never a public API). The runtime keeps one-line public delegators so EVERY call site
# (overworld_entity_actions, playtest_bot_entity, the app checks) stays unchanged.
#
# DETERMINISM: NO rng here — egg payloads ride Breeding.build_egg on a null rng (the nonce
# rolls are OVERWRITTEN with the spawn-time gender/shiny), and recruitment stamps via the
# runtime's _stamp_instance (the shared _rng is never consumed — the pinned stream is untouched).

const OverworldMons := preload("res://scripts/domain/overworld_mons.gd")
const Breeding := preload("res://scripts/domain/breeding.gd")

const INTERACT_MEMORY_STEPS := 16 # an irritable's warning lapses after this many quiet steps

# The overworld_mons_runtime back-reference is a WEAKREF (the sim precedent): the runtime
# holds this object strongly, so a strong back-ref would be a RefCounted cycle that never
# frees at exit (leaking the runtime's catalog/trace refs — the "resources still in use" red).
var _rt_ref := WeakRef.new()

func setup(rt) -> void:
	_rt_ref = weakref(rt)

func _rt(): # the overworld_mons_runtime back-reference (weakref deref)
	return _rt_ref.get_ref()

# An egg is the :248 shiny-check + clear (NO battle, NO aggro); a mon is a player-initiated
# forced battle — provoked:false, so NO +3 buff (:280).
func attack_entity(tile: Vector2i) -> Dictionary:
	var entity: Dictionary = _rt().entity_at(tile)
	if entity.is_empty():
		return {"ok": false, "reason": "no_target"}
	if str(entity.get("kind", "")) == "egg":
		var shiny := bool(entity.is_shiny)
		_rt()._emit("egg_cleared", {"tile": _rt()._t(entity.tile), "species_id": str(entity.species_id), "is_shiny": shiny})
		_rt()._remove_entity(entity, OverworldMons.REASON_CAUGHT)
		return {"ok": true, "egg_cleared": true, "is_shiny": shiny,
			"message": "The egg gleams oddly... It's SHINY!" if shiny else "The egg breaks apart. It was not shiny."}
	return _rt()._force_battle(entity, false)

# Z on a chamber legendary provokes its +3 battle through the normal presentation bridge.
# Otherwise FRIENDLY (or Charmed) recruits; IRRITABLE warns, then chases on a second Z.
func interact(tile: Vector2i) -> Dictionary:
	var entity: Dictionary = _rt().entity_at(tile)
	if entity.is_empty():
		return {"ok": false, "reason": "no_entity", "message": ""}
	if str(entity.get("kind", "")) == "egg":
		return egg_take(tile)
	if str(entity.get("kind", "")) == "legendary":
		return _rt()._force_battle(entity, true)
	var disposition: String = _rt()._disposition_now(entity)
	if disposition == OverworldMons.DISPOSITION_FRIENDLY or int(entity.get("pacify_steps", 0)) > 0:
		return _recruit(entity)
	if disposition != OverworldMons.DISPOSITION_IRRITABLE or str(entity.get("state", "idle")) != "idle":
		return {"ok": false, "reason": "not_friendly", "message": "It isn't interested in joining you."}
	var total_steps := int(_rt()._session.total_steps)
	var consecutive: bool = _rt()._last_interact_id == str(entity.id) and _rt()._last_interact_step + INTERACT_MEMORY_STEPS >= total_steps
	_rt()._last_interact_id = str(entity.id); _rt()._last_interact_step = total_steps
	if not consecutive:
		return {"ok": false, "reason": "wary", "message": "It's eyeing you warily."}
	entity["state"] = "chasing"
	_rt()._emit("mon_provoked", {"slot": str(entity.id), "species_id": str(entity.species_id), "tile": _rt()._t(entity.tile), "cause": "interact"})
	return {"ok": false, "reason": "provoked", "message": "It lunged at you!"}

# TAKE a wild egg: the Phase-5 party-egg payload (Breeding.build_egg on a null rng — the
# nonce rolls are OVERWRITTEN with the spawn-time gender/shiny, so the shared _rng is never
# touched and the existing step-incubation hatches it at level 5), egg_stolen, THEN
# provocation — parents AND egg-group sharers within EGG_PROVOKE_RADIUS chase (DIVERGENCE
# #5), a nest guardian in range forces its +3 battle (:248/:284).
func egg_take(tile: Vector2i) -> Dictionary:
	var entity: Dictionary = _rt().entity_at(tile)
	if entity.is_empty() or str(entity.get("kind", "")) != "egg":
		return {"ok": false, "reason": "no_egg", "message": "There is no egg there."}
	var session = _rt()._session
	if int(session.party.size()) >= 6:
		return {"ok": false, "reason": "party_full", "message": "Your party is full. The egg stays where it is."}
	var species_id := str(entity.species_id)
	var catalog = _rt()._catalog
	var entry: Dictionary = catalog.get_species(species_id)
	var egg_mon: Dictionary = Breeding.build_egg({}, {}, entry, Callable(catalog, "get_move"), null, "overworld:" + species_id)
	egg_mon["is_shiny"] = bool(entity.is_shiny)
	var egg_data: Dictionary = egg_mon.get("egg", {})
	egg_data["gender"] = str(entity.gender); egg_data["is_shiny"] = bool(entity.is_shiny)
	if not session.add_pokemon_to_party(egg_mon):
		return {"ok": false, "reason": "party_full", "message": "Your party is full. The egg stays where it is."}
	_rt()._remove_entity(entity, OverworldMons.REASON_CAUGHT) # no overworld_mon_despawned for eggs
	var provoked: Array = [] # collect first so egg_stolen traces BEFORE the provocation
	for other in _rt()._live_list():
		if str(other.get("kind", "")) != "egg" and OverworldMons.in_egg_provoke_range(other.tile, tile) and OverworldMons.is_provoked_by_egg(str(other.species_id), catalog.get_species(str(other.species_id)), species_id, entry):
			provoked.append(other)
	_rt()._emit("egg_stolen", {"tile": _rt()._t(tile), "species_id": species_id, "is_shiny": bool(entity.is_shiny), "provoked_count": provoked.size()})
	for other in provoked:
		other["state"] = "chasing"
		_rt()._emit("mon_provoked", {"slot": str(other.id), "species_id": str(other.species_id), "tile": _rt()._t(other.tile), "cause": "egg_theft"})
		if str(other.get("kind", "")) == "guardian" and _rt()._pending.is_empty() and not _rt()._last_battle_was_entity: # the step-driven arms guard the seam; the FIRST in-range guardian battles, a second stays chasing (never a silent overwrite of the armed mon)
			_rt()._force_battle(other, true) # alpha_provoked + the pending seam inside
	return {"ok": true, "species_id": species_id, "message": "You took the wild egg."}

func _recruit(entity: Dictionary) -> Dictionary:
	var species_id := str(entity.species_id)
	var session = _rt()._session
	if int(session.party.size()) >= 6:
		_rt()._emit("recruit_attempted", {"species_id": species_id, "tile": _rt()._t(entity.tile), "path": "dialogue", "party_free": false, "ok": false, "reason": "party_full"})
		return {"ok": false, "reason": "party_full", "message": "Your party is full. It won't just wait at your camp."} # :262
	var mon: Dictionary = _rt()._stamp_instance(entity, int(entity.get("level", 5)))
	if mon.is_empty():
		return {"ok": false, "reason": "no_species", "message": ""}
	_rt()._emit("recruit_attempted", {"species_id": species_id, "tile": _rt()._t(entity.tile), "path": "dialogue", "party_free": true, "ok": true, "reason": ""})
	session.add_pokemon_to_party(mon)
	var tile: Vector2i = entity.tile; var level := int(entity.level); var is_shiny := bool(entity.is_shiny)
	_rt()._remove_entity(entity, OverworldMons.REASON_CAUGHT)
	_rt()._emit("recruit_succeeded", {"species_id": species_id, "tile": _rt()._t(tile), "level": level, "is_shiny": is_shiny, "party_size": session.party.size()})
	return {"ok": true, "reason": "", "message": "Wild %s joined your party!" % str(mon.get("name", species_id))}

# The Phase-4 hooks (field_move_runtime.use_attack/use_charm call these post-trace).
func on_attack_hook(species_id: String) -> void:
	var entity := _resolve_faced(species_id)
	if not entity.is_empty():
		attack_entity(entity.tile)

func on_charm_hook(species_id: String, pacified: bool) -> void:
	var entity := _resolve_faced(species_id)
	if entity.is_empty() or str(entity.get("kind", "")) == "egg" or not pacified:
		return
	entity["pacify_steps"] = OverworldMons.CHARM_CALM_STEPS
	if ["fleeing", "chasing"].has(str(entity.get("state", "idle"))): # Charm PREVENTS flight/attack (:254/:278)
		entity["state"] = "idle"; entity["flee_steps"] = 0

func _resolve_faced(species_id: String) -> Dictionary:
	var rt = _rt()
	var faced: Dictionary = rt.entity_at(rt._faced_tile) if rt._faced_tile != Vector2i.MAX else {}
	if not faced.is_empty() and str(faced.get("species_id", "")) == species_id:
		return faced
	var best: Dictionary = {} # fallback: adjacent + species-match, lowest id (deterministic)
	for entity in rt._live_list():
		if str(entity.get("species_id", "")) == species_id and OverworldMons.is_adjacent(entity.tile, rt._session.player_tile) and (best.is_empty() or str(entity.id) < str(best.id)):
			best = entity
	return best
