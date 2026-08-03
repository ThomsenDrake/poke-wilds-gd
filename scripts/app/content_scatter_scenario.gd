extends Node

# Content-scatter scenario (infinite-world slice 3; spec: world-depth.md — successor
# infinite-world.md in slice 5). Witnesses the chunk-hash scattering beyond the origin
# core, self-pinned seed_for_smoke(SEED) -> new_game -> rebuild: (1) ORIGIN-CORE
# PRESERVATION — landmarks_in_world still returns EXACTLY the three byte-frozen origin
# anchors (scatter never pollutes the core); (2) SCATTER DISCOVERY — at least one
# scattered landmark instance derives beyond the core, its instance key parses; (3)
# PER-INSTANCE STATE — crafting a scattered mansion's puzzle through the frozen seam
# opens ITS doors while the origin mansion stays sealed (independent keys, never a
# whole-dict clobber); (4) LAIR LIFECYCLE — a repeating lair stamps window-scoped, a KO
# removes it gone-for-good PER INSTANCE (anchor-keyed removal), and a same-species
# sibling lair elsewhere still spawns. NOT a double-run consumer (the origin pins ride
# the lane); deterministic by construction (pure _mix + FastNoiseLite).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const LandmarkRuntime := preload("res://scripts/runtime/landmark_runtime.gd")
const OverworldMonsRuntime := preload("res://scripts/runtime/overworld_mons_runtime.gd")
const Landmarks := LandmarkRuntime.Landmarks
const LandmarkScatter := LandmarkRuntime.LandmarkScatter
const ContentScatter := LandmarkRuntime.ContentScatter
const LegendaryPlacement := OverworldMonsRuntime.LegendaryPlacement
const OverworldMonsLairs := preload("res://scripts/runtime/overworld_mons_lairs.gd") # the lair id grammar (single-sourced, never duplicated)

const SEED := 2026080301
const DAY_MINUTES := 600
const SCAN_RADII := [31, 63, 95] # expanding chunk-radius scan (lairs are 3‰/species/chunk — the scan widens until both goals land; measured: a pair lands by radius 63 on the pinned seed)
const SEWER_DOOR_LOCAL := Vector2i(4, 5) # landmark_flow's constant: the mansion sewer door local

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _oks: Dictionary = {}

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	runtime.seed_for_smoke(SEED)
	runtime.new_game()
	_world().rebuild(runtime.get_world_seed())
	runtime.session.time_of_day_minutes = DAY_MINUTES
	var party_before: Array = _runner.swap_party(runtime, ["RHYPERIOR", "MACHAMP"], 100)
	var saved_chance: float = _player().encounter_chance; _player().encounter_chance = 0.0
	_call("set_battle", [true]) # every forced battle stays on the DIRECT seam (the legendary_spawn precedent)
	var found: Dictionary = _scan(runtime.get_world_seed()) # ONE scan feeds both proofs (mansion instance + lair list)
	_oks["origin_ok"] = _prove_origin_core(runtime)
	if _failures.is_empty(): _oks["scatter_ok"] = _prove_scatter(runtime, found)
	else: _failures.append("skipped: scatter (cascaded from an origin red)")
	if _failures.is_empty(): _oks["lair_ok"] = _prove_lair_lifecycle(runtime, found)
	else: _failures.append("skipped: lairs (cascaded from an earlier red)")
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["pin"] = SEED; payload["seed"] = runtime.get_world_seed()
		runtime.emit_trace("content_scatter_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("content_scatter_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("ContentScatterScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
	_call("set_battle", [false])
	_runner.restore_party(runtime, party_before)
	_player().encounter_chance = saved_chance; _player().input_enabled = true
	runtime.session.time_of_day_minutes = DAY_MINUTES

# The three origin anchors are byte-frozen AND the scatter never pollutes the core:
# landmarks_in_world returns exactly the origin three (the scenario/audit contract).
func _prove_origin_core(runtime) -> bool:
	var start: int = _failures.size()
	var seed: int = runtime.get_world_seed()
	var origin: Array = Landmarks.landmarks_in_world(seed, Vector2i.ZERO)
	_ensure(origin.size() == 3, "origin: landmarks_in_world returned %d entries (the origin core must stay exactly three)" % origin.size())
	for landmark in origin:
		var lid := str(landmark.get("landmark_id", ""))
		var derived: Vector2i = Landmarks.anchor_for(seed, Vector2i.ZERO, lid)
		_ensure(landmark.get("anchor", Vector2i.MAX) == derived, "origin: %s anchor drifted from the byte-frozen derivation" % lid)
	return _failures.size() == start

# Scatter discovery + per-instance state: find a scattered mansion beyond the core, craft
# ITS puzzle through the frozen seam, and prove the origin mansion stays sealed.
func _prove_scatter(runtime, found: Dictionary) -> bool:
	var start: int = _failures.size()
	var seed: int = runtime.get_world_seed()
	var mansion: Dictionary = found.get("mansion", {})
	if mansion.is_empty():
		return _ensure(false, "scatter: no scattered mansion instance within the chunk scan (density/derivation regression)")
	var parsed := ContentScatter.parse_instance_key(str(mansion.get("instance_key", "")))
	if not _ensure(not parsed.is_empty() and parsed["id"] == Landmarks.MANSION_ID, "scatter: the instance key %s did not parse to a mansion" % str(mansion.get("instance_key", ""))):
		return false
	var origin_mansion := {}
	for landmark in Landmarks.landmarks_in_world(seed, Vector2i.ZERO):
		if str(landmark.get("landmark_id", "")) == Landmarks.MANSION_ID:
			origin_mansion = landmark
	var state := {"statues": [true, true, true], "unlocked": true, "key_taken": true}
	var all: Dictionary = runtime.session.landmark_state_for(Vector2i.ZERO)
	all[str(mansion["instance_key"])] = state
	runtime.session.set_landmark_state(Vector2i.ZERO, all) # the frozen seam MERGES by key (never a whole-dict replace)
	_ensure(runtime.session.landmark_state_for(Vector2i.ZERO).size() == 1, "scatter: crafting the scattered mansion leaked state into a sibling instance")
	var scattered_door: Dictionary = _world().get_tile_logic((mansion["footprint"] as Rect2i).position + SEWER_DOOR_LOCAL)
	_ensure(bool(scattered_door.get("walkable", false)), "scatter: the crafted mansion's sewer door stayed sealed (per-instance state resolution broken)")
	if not origin_mansion.is_empty():
		var origin_door: Dictionary = _world().get_tile_logic((origin_mansion["footprint"] as Rect2i).position + SEWER_DOOR_LOCAL)
		_ensure(not bool(origin_door.get("walkable", false)), "scatter: the origin mansion's door opened from a scattered instance's state (keying collision)")
	return _failures.size() == start

# Lair lifecycle: a lair stamps window-scoped, a KO removes it per-instance (anchor key),
# and a same-species sibling lair elsewhere still spawns.
func _prove_lair_lifecycle(runtime, found: Dictionary) -> bool:
	var start: int = _failures.size()
	var lairs: Array = found.get("lairs", [])
	var pair: Array = [] # two same-species lairs
	var by_species := {}
	for lair in lairs:
		var sid := str(lair.get("species_id", ""))
		if not by_species.has(sid):
			by_species[sid] = []
		(by_species[sid] as Array).append(lair)
		if (by_species[sid] as Array).size() == 2:
			pair = by_species[sid]
	if not _ensure(pair.size() == 2, "lair: the scan found no same-species lair pair among %d lairs (density regression)" % lairs.size()):
		return false
	var victim: Dictionary = pair[0]; var sibling: Dictionary = pair[1]
	var sid := str(victim.get("species_id", ""))
	var mons = runtime.overworld_mons_runtime
	mons.active = true # lairs ride the window sync (the smoke activation opt-out; restored at exit)
	_runner.teleport_player(_world(), _player(), runtime, victim["anchor"] + Vector2i(3, 3)) # beside, never ON: contact shares a tile, and the spawn only needs the window
	runtime.note_player_step() # the window sync stamps the lair
	var id := OverworldMonsLairs.lair_id(victim["anchor"], sid)
	var entity: Dictionary = mons._entities.get(id, {})
	if not _ensure(not entity.is_empty() and str(entity.get("battle_kind", "")) == "legendary", "lair: %s did not stamp window-scoped at %s (entity id %s)" % [sid, str(victim["anchor"]), id]):
		return false
	var atk: Dictionary = mons.attack_entity(victim["anchor"])
	if not _ensure(bool(atk.get("ok", false)), "lair: the lair refused engagement (%s)" % str(atk.get("reason", ""))):
		return false
	var battle_mon: Dictionary = runtime.generate_wild_encounter(_player().tile_position, _world().get_tile_biome(_player().tile_position))
	battle_mon["current_hp"] = 1
	runtime.start_wild_battle(battle_mon)
	runtime.battle_runtime._player_mon["max_hp"] = 9999; runtime.battle_runtime._player_mon["current_hp"] = 9999 # the KO lands whatever the level/speed order
	var outcome := "" # bounded turn loop: an accuracy miss keeps the battle open (the player cannot lose at hp 9999)
	for _turn in range(24):
		var response: Dictionary = runtime.perform_battle_move(_damaging_move_index(runtime.battle_runtime._player_mon))
		if bool(response.get("finished", false)):
			outcome = str(response.get("outcome", ""))
			break
	if not _ensure(outcome == "victory", "lair: the KO battle ended '%s' (no finish within the turn cap)" % outcome):
		return false
	var key := LegendaryPlacement.removal_key(victim["anchor"], sid)
	_ensure((runtime.session.legendary_removals as Array).has(key), "lair: the removal key %s never reached session.legendary_removals (%s)" % [key, str(runtime.session.legendary_removals)])
	_runner.teleport_player(_world(), _player(), runtime, victim["anchor"] + Vector2i(3, 3))
	runtime.note_player_step() # re-sync: the removed lair must NOT re-derive
	_ensure(mons._entities.get(id, {}).is_empty(), "lair: the KO'd lair re-spawned on re-sync (per-instance suppression broken)")
	_runner.teleport_player(_world(), _player(), runtime, sibling["anchor"] + Vector2i(3, 3))
	runtime.note_player_step() # the sibling lair (same species) must STILL spawn
	var sib_id := OverworldMonsLairs.lair_id(sibling["anchor"], sid)
	_ensure(not mons._entities.get(sib_id, {}).is_empty(), "lair: the sibling lair %s was suppressed by its sibling's removal (removals are per-instance, never per-species)" % sib_id)
	mons.active = false
	return _failures.size() == start

# The chunk scan: scattered mansion instances + lair derivations beyond the origin core
# (chunk-center ring > 96, the scatter gate), over EXPANDING radii until both goals land —
# a scattered mansion AND a same-species lair pair. Lairs pre-filter by the chunk center's
# live biome so the domain roll only runs on affinity chunks (the scan stays ~1s at cap).
func _scan(seed: int) -> Dictionary:
	var out := {"mansion": {}, "lairs": []}
	var seen := {}
	var counts := {} # species -> lair count (the pair check)
	for rmax in SCAN_RADII:
		for cy in range(-int(rmax), int(rmax) + 1):
			for cx in range(-int(rmax), int(rmax) + 1):
				var chunk := Vector2i(cx, cy)
				if seen.has(chunk):
					continue
				seen[chunk] = true
				var center := chunk * ContentScatter.CONTENT_CHUNK + Vector2i(ContentScatter.CONTENT_CHUNK / 2, ContentScatter.CONTENT_CHUNK / 2)
				if ContentScatter.ring_of(center) <= 96:
					continue
				if (out["mansion"] as Dictionary).is_empty():
					var instance := LandmarkScatter.instance_for_chunk(seed, chunk)
					if not instance.is_empty() and str(instance.get("landmark_id", "")) == Landmarks.MANSION_ID:
						out["mansion"] = instance
				var biome: String = _world().get_tile_biome(center)
				for species_id in LegendaryPlacement.LEGENDARY_IDS:
					if LegendaryPlacement.affinity_for(str(species_id)) != biome:
						continue
					var anchor: Vector2i = LegendaryPlacement.lair_for_chunk(seed, chunk, str(species_id))
					if anchor != LegendaryPlacement.NO_ANCHOR:
						(out["lairs"] as Array).append({"species_id": str(species_id), "anchor": anchor})
						counts[str(species_id)] = int(counts.get(str(species_id), 0)) + 1
		if not (out["mansion"] as Dictionary).is_empty():
			for c in counts.values():
				if int(c) >= 2:
					return out # both goals landed at this radius
	return out

func _damaging_move_index(mon: Dictionary) -> int: # the legendary_spawn exclusions: heal/leech never end the KO path
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		var move: Dictionary = moves[i]
		if int(move.get("power", 0)) > 0 and int(move.get("pp", 0)) > 0 and str(move.get("effect", "")) != "EFFECT_LEECH_HIT" and str(move.get("effect", "")) != "EFFECT_HEAL":
			return i
	return 0

func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok

func _call(key: String, args: Array = []) -> void:
	var callable: Callable = _ctx.get(key, Callable())
	if callable.is_valid(): callable.callv(args)

func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
