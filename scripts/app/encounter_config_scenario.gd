extends Node

# Configurable-encounter gate scenario (spec: overworld-pokemon.md § Configurable encounters).
# Proves the FOUR contracts of the collision-only default + the opt-in: (a) DEFAULT OFF — the
# crafted world reports mode "off", the per-step roll fires ZERO encounters on an encounter
# tile, yet a shared-tile CONTACT with an idle mon forces a provoked:false / NO-buff battle
# and an egg on the player's tile does NOT; (b) CLASSIC — at a high rate the roll fires on an
# encounter tile and never off one; (c) ANYWHERE — it fires on a non-encounter walkable tile;
# (d) ROUND-TRIP — a non-default setting survives save -> reload exactly, and switching back
# to OFF drops the additive key (byte-preservation — the v4 golden carries none). Determinism:
# the world is CRAFTED on the pinned seed (overworld_mons craft_state precedent — explicit
# world_seed, pin_craft_world before spawn so landmark_resolver cannot consult the boot
# wall-clock session seed, synchronous rebuild + teleport, NEVER new_game); seed_for_smoke
# pins the avatar trigger stream; tiles ride world.get_tile_logic (not the render cache);
# the forced-battle seam + main's encounter handler are owned for the run (overworld_mons
# bridge precedent). Emits encounter_config_passed/failed (miss-002).

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const OverworldMonsProbe := preload("res://scripts/runtime/overworld_mons_probe.gd")

const SEED := 2026072901 # calibrated pin (world seed + rng pin; distinct from the other gates)
const DAY_MINUTES := 600
const ROLLS := 20 # per-case roll budget (a high rate makes a zero-hit run ~1e-6, never a flake)
const HIGH_RATE := 0.50
const ROUND_TRIP_RATE := 0.24

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _baselines = VisualSweepBaselines.new()
var _probe = OverworldMonsProbe.new()
var _failures: Array = []
var _oks: Dictionary = {}
var _bridge_disconnected := false
var _main_disconnected := false
var _emissions := 0

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	var player = _player()
	var mons: Object = runtime.get("overworld_mons_runtime")
	var party_before: Array = runtime.session.party
	var saved_chance: float = player.encounter_chance
	runtime.seed_for_smoke(SEED) # BEFORE any draw: pins the avatar trigger stream the rolls ride + the shared rng
	var spec := {"world_seed": SEED, "time_of_day": DAY_MINUTES, "bag": {}, "party": [["MACHOP", 30]]}
	var crafted := _baselines.craft_state(_ctx, _runner, spec) # explicit world seed: a pure function of SEED, never new_game
	_reset_entities(mons) # a clean live store (boot leftovers dropped) so the entity timeline is the crafted one
	_disconnect_bridge(runtime)
	_disconnect_main(player)
	_ensure(crafted, "setup: the crafted world failed")
	if crafted and _failures.is_empty():
		_oks["default_off_ok"] = _case_default_off(runtime, mons)
	if crafted and _failures.is_empty():
		_oks["classic_ok"] = _case_mode(runtime, "classic")
	if crafted and _failures.is_empty():
		_oks["anywhere_ok"] = _case_mode(runtime, "anywhere")
	if crafted and _failures.is_empty():
		_oks["round_trip_ok"] = _case_round_trip(runtime)
	if _failures.is_empty():
		var payload: Dictionary = _oks.duplicate(); payload["seed"] = SEED
		runtime.emit_trace("encounter_config_passed", "SmokeScenarios", payload)
	else:
		runtime.emit_trace("encounter_config_failed", "SmokeScenarios", {"failures": _failures, "seed": SEED})
		push_error("EncounterConfigScenario failed: %s" % "; ".join(PackedStringArray(_failures)))
		runtime.warn("SmokeScenarios", "Encounter config scenario failed.", {})
	mons.take_pending_encounter() # never leave an armed seam for the dispatcher's teardown
	_reset_entities(mons)
	_reconnect_bridge(runtime)
	_reconnect_main(player)
	runtime.session.encounter_settings = {}; runtime.session.party = party_before
	runtime.session.repel_steps = 0; runtime.session.time_of_day_minutes = DAY_MINUTES
	player.encounter_chance = saved_chance; player.input_enabled = true
	_world().set_time_of_day(DAY_MINUTES)

# (a) Fresh save == off; the roll is silent on an encounter tile; contact forces a battle; an egg does not.
func _case_default_off(runtime, mons) -> bool:
	var player = _player()
	var ok := _ensure(str(runtime.session.get_encounter_settings().get("mode", "")) == "off", "default: a fresh save is not mode off")
	var encounter_tile := _find_tile(true)
	ok = _ensure(encounter_tile != Vector2i.MAX, "default: no walkable encounter tile within scan") and ok
	if encounter_tile != Vector2i.MAX:
		_runner.teleport_player(_world(), player, runtime, encounter_tile)
		ok = _ensure(_count_rolls(player, ROLLS) == 0, "default: the roll fired a random encounter while mode was off") and ok
	ok = _ensure(_contact_arms(runtime, mons), "contact: stepping onto an idle mon did not force a provoked:false battle") and ok
	ok = _ensure(_egg_is_exempt(runtime, mons), "contact: an egg on the player's tile armed a battle") and ok
	return ok

func _case_mode(runtime, mode: String) -> bool: # (b)/(c) a high rate fires where the mode allows, nowhere else
	var player = _player()
	runtime.session.set_encounter_settings(mode, HIGH_RATE)
	var encounter_tile := _find_tile(true)
	var open_tile := _find_tile(false)
	var ok := _ensure(encounter_tile != Vector2i.MAX and open_tile != Vector2i.MAX, "%s: no encounter/open tile pair within scan" % mode)
	if not ok:
		return false
	_runner.teleport_player(_world(), player, runtime, encounter_tile)
	var on_encounter := _count_rolls(player, ROLLS)
	_runner.teleport_player(_world(), player, runtime, open_tile)
	var on_open := _count_rolls(player, ROLLS)
	if mode == "classic":
		return _ensure(on_encounter > 0, "classic: %d rolls on an encounter tile fired nothing" % ROLLS) \
			and _ensure(on_open == 0, "classic: the roll fired %d times OFF an encounter tile" % on_open)
	return _ensure(on_open > 0, "anywhere: %d rolls on an open walkable tile fired nothing" % ROLLS)

func _case_round_trip(runtime) -> bool: # (d) a non-default setting round-trips exactly; off drops the additive key
	runtime.session.set_encounter_settings("classic", ROUND_TRIP_RATE)
	var payload: Dictionary = _runner.save_and_reload(_world(), runtime)
	var stored: Variant = payload.get("encounter_settings", {})
	var ok := _ensure(stored is Dictionary and str((stored as Dictionary).get("mode", "")) == "classic", "round-trip: the classic mode did not survive save -> reload")
	ok = _ensure(ok and absf(float(runtime.session.get_encounter_settings().get("rate", 0.0)) - ROUND_TRIP_RATE) < 1e-9, "round-trip: the rate drifted across save -> reload")
	runtime.session.set_encounter_settings("off", ROUND_TRIP_RATE) # off with any rate -> canonical {}
	var payload_off: Dictionary = _runner.save_and_reload(_world(), runtime)
	return _ensure(not payload_off.has("encounter_settings"), "round-trip: off rode the save (the v4 golden carries no encounter_settings key)") and ok

# Teleport onto an injected idle mon's tile; one step must arm the seam provoked:false (no +3),
# species intact; resolve via the public outcome seam (escaped -> mon stays, idle).
func _contact_arms(runtime, mons) -> bool:
	var player = _player()
	var record: Dictionary = _probe.inject_entity(_world(), mons, player.tile_position, "EEVEE", "FRIENDLY", 3, "")
	if record.is_empty():
		return _ensure(false, "contact: no walkable tile to inject an idle mon within 3 rings")
	mons.take_pending_encounter()
	_runner.teleport_player(_world(), player, runtime, record.tile)
	runtime.note_player_step()
	var pending: Dictionary = mons.call("take_pending_encounter")
	if not _ensure(not pending.is_empty(), "contact: the seam was empty after stepping onto the mon"):
		return false
	var ok := _ensure(int(pending.get("attack_stages", 0)) == 0, "contact: the forced battle carried a buff (provoked should be false)")
	ok = _ensure(str(pending.get("species_id", "")) == "EEVEE", "contact: the forced battle was not the collided mon") and ok
	mons.call("note_battle_outcome", "escaped", pending) # public seam: drops the engaged mark, mon -> idle
	return ok

func _egg_is_exempt(runtime, mons) -> bool: # poke a minimal egg on a clear tile; one step on it must NOT arm the seam
	var player = _player()
	var tile := _find_clear_walkable(mons)
	if tile == Vector2i.MAX:
		return _ensure(false, "egg: no clear walkable tile within scan")
	var cell := Vector2i(floori(float(tile.x) / 8.0), floori(float(tile.y) / 8.0))
	mons._entities["cfg_egg"] = {"id": "cfg_egg", "kind": "egg", "species_id": "EEVEE", "tile": tile, "cell": cell,
		"level": 5, "is_shiny": false, "gender": "female", "state": "idle"}
	mons.take_pending_encounter()
	_runner.teleport_player(_world(), player, runtime, tile)
	runtime.note_player_step()
	var pending: Dictionary = mons.call("take_pending_encounter")
	var exempt := _ensure(pending.is_empty(), "egg: stepping onto an egg armed a battle")
	mons._entities.erase("cfg_egg")
	return exempt

# ROLL counting: own the player's encounter_requested for the burst (main's handler disconnected), call the avatar's trigger N times.
func _count_rolls(player, count: int) -> int:
	_emissions = 0
	var counter := Callable(self, "_on_roll_emitted")
	player.encounter_requested.connect(counter)
	for _i in range(count):
		player._try_trigger_encounter() # private-call precedent: seed_for_smoke pokes player_avatar._rng
	player.encounter_requested.disconnect(counter)
	return _emissions

func _on_roll_emitted(_tile: Vector2i) -> void:
	_emissions += 1

# Tile discovery on the GENERATOR logic (never the render cache — deterministic far from the synced window).
func _find_tile(want_encounter: bool) -> Vector2i:
	var center: Vector2i = _player().tile_position
	for radius in range(0, 48):
		for tile in _probe.ring(center, radius):
			var logic: Dictionary = _world().get_tile_logic(tile)
			if bool(logic.get("walkable", false)) and bool(logic.get("encounter", false)) == want_encounter:
				return tile
	return Vector2i.MAX

func _find_clear_walkable(mons) -> Vector2i:
	var center: Vector2i = _player().tile_position
	for radius in range(1, 48):
		for tile in _probe.ring(center, radius):
			if not bool(_world().get_tile_logic(tile).get("walkable", false)):
				continue
			if (mons.call("entity_at", tile) as Dictionary).is_empty():
				return tile
	return Vector2i.MAX

# A fresh derivation on the crafted seed (overworld_mons reset_entities precedent): drops boot leftovers so the entity timeline is a pure function of the crafted world.
func _reset_entities(mons) -> void:
	mons._entities.clear(); mons._removed.clear(); mons._nests_found.clear(); mons._pool_cache.clear()
	mons._pending = {}; mons._pending_id = ""; mons._last_battle_was_entity = false
	mons._time_label = ""; mons._faced_tile = Vector2i.MAX; mons._last_interact_id = ""; mons._last_interact_step = -100
	mons.active = true

# Seam ownership (overworld_mons bridge precedent): arming pending must never auto-start main's battle presentation, nor the roll burst reach it.
func _disconnect_bridge(runtime) -> void:
	var target := Callable(runtime, "_on_entity_encounter")
	if runtime.overworld_mons_runtime.encounter_requested.is_connected(target):
		runtime.overworld_mons_runtime.encounter_requested.disconnect(target); _bridge_disconnected = true

func _reconnect_bridge(runtime) -> void:
	var target := Callable(runtime, "_on_entity_encounter")
	if _bridge_disconnected and not runtime.overworld_mons_runtime.encounter_requested.is_connected(target):
		runtime.overworld_mons_runtime.encounter_requested.connect(target)

func _disconnect_main(player) -> void:
	var main := get_node_or_null("/root/Main")
	if main != null and player.encounter_requested.is_connected(Callable(main, "_on_encounter_requested")):
		player.encounter_requested.disconnect(Callable(main, "_on_encounter_requested")); _main_disconnected = true

func _reconnect_main(player) -> void:
	var main := get_node_or_null("/root/Main")
	if main != null and _main_disconnected and not player.encounter_requested.is_connected(Callable(main, "_on_encounter_requested")):
		player.encounter_requested.connect(Callable(main, "_on_encounter_requested"))

func _ensure(ok: bool, label: String) -> bool:
	if not ok:
		_failures.append(label)
	return ok

func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
