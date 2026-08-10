extends Node

# SAVE STABILITY pin (pre-Phase-7 suite; v6-guarded in infinite-world slice 1): new_game
# under seed_for_smoke, scripted v4-surface mutations (campsite deposit/withdraw,
# stone/rod bag, repel_steps, pastures), then save -> reload -> save with a
# byte-compare of the CANONICALIZED payload (keys sorted, ts/version stripped —
# JSON.stringify has NO ordering guarantee, so the canonicalizer, not the engine,
# owns stability). The committed golden at docs/generated/golden-saves/v4_golden.json
# STAYS a v4 fixture — the migration WITNESS: the guard canonicalizes
# SaveMigration.migrate(golden) before the compare (the ONLY pinned guard change), so
# live v6 == migrated golden exactly (chain-less + puzzle-untouched => the delta is
# precisely the version key; slice 3's instance re-key normalizes any landmark_state).
# mode=update DOWNSHIFTS first so the witness regenerates v4-shaped; an unrepresentable
# write is REFUSED + traced. (The world_chain round-trip sublane RETIRED with chaining.)
# miss-002: a red names its cause.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")
const Sites := preload("res://scripts/runtime/phase5_sites.gd")
const Phase5 := preload("res://scripts/runtime/phase5_support.gd")
const SaveStabilitySupport := preload("res://scripts/app/save_stability_support.gd")
const SessionState := preload("res://scripts/runtime/session_state.gd")
# Domain access rides the runtime's own preload (the app layer may not preload domain
# directly — check_architecture.gd's layer table; the landmark_flow precedent).
const SaveMigration := SessionState.SaveMigration

const SEED := 2026072802 # save-stability pin (distinct from the joint-pin / soak seeds)
const PEN_SCAN_RADIUS := 400 # wider than breed_flow's 160: the fresh-seeded world's tree bands sit far out from the origin spawn (the pen's LOCATION is irrelevant to save stability — any site proves the surface)
const GOLDEN_PATH := "res://docs/generated/golden-saves/v4_golden.json"

var _ctx: Dictionary = {}
var _runner = SmokeScenarioRunner.new()
var _reasons: Array = []


func run(ctx: Dictionary, extra: Dictionary = {}) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = _runtime()
	var update := str(extra.get("mode", "")) == "update"
	runtime.seed_for_smoke(SEED) # before new_game: pins the world-seed draw too
	runtime.new_game()
	# Pin the golden's creation identity: new_game deliberately INHERITS the boot session's
	# player_name/player_avatar/shiny_odds_choice (session_state.gd's "creation identity
	# persists across new games"), so an un-pinned craft drifts with whatever save the boot
	# loaded (2026-08-09 gate: a leftover GOLD-named save turned the golden diff red).
	runtime.session.player_name = "AAA" # the golden's pinned name
	runtime.session.player_avatar = SessionState.DEFAULT_PLAYER_AVATAR
	runtime.session.shiny_odds_choice = SessionState.SHINY_ODDS_DEFAULT
	_mutate_v4_surface(runtime)
	runtime.save_game()
	var canon_a := _canon_str(_payload(runtime))
	var reloaded: Dictionary = runtime.save_store.load_payload()
	_ensure(not reloaded.is_empty() and runtime._apply_loaded_payload(reloaded), "reload: the just-written payload failed to re-apply")
	runtime.save_game()
	var canon_b := _canon_str(_payload(runtime))
	if canon_a == canon_b:
		_ensure(true, "")
	else:
		var diff: Array = _diff_paths(JSON.parse_string(canon_a), JSON.parse_string(canon_b))
		_ensure(false, "stability: the canonical save drifted across save -> reload -> save (%s)" % "; ".join(PackedStringArray(diff.slice(0, 8))))
	if update:
		SaveStabilitySupport.update_golden(runtime, canon_a, _canon_str, _write_golden, _ensure)
	else:
		_check_golden(runtime, canon_a)
	# (The v5 world_chain round-trip sublane retired with world chaining — infinite-world slice.)
	if _reasons.is_empty():
		runtime.emit_trace("save_stability_passed", "SmokeScenarios", {"seed": SEED,
			"mode": "update" if update else "verify", "canon_bytes": canon_a.length(), "digest": abs(canon_a.hash())})
	else:
		runtime.emit_trace("save_stability_failed", "SmokeScenarios", {"seed": SEED,
			"mode": "update" if update else "verify", "reasons": _reasons})
		push_error("SaveStabilityScenario failed: %s" % "; ".join(PackedStringArray(_reasons)))
		runtime.warn("SaveStabilityScenario", "Save stability failed.", {"reasons": _reasons})


# Scripted mutations across every v4 save surface the port owns: bag (stone + rod),
# the Phase-4 repel counter, the v4 pastures key, and the campsite hold (a deposit
# pair + one runtime-routed withdraw). The world seed is pinned upstream, so the
# canonical payload is a pure function of (code, seed, these mutations).
func _mutate_v4_surface(runtime) -> void:
	var catalog = runtime.catalog
	var get_move := Callable(catalog, "get_move")
	var eevee: Dictionary = runtime.pokemon_rules.create_pokemon_instance(catalog.get_species("EEVEE"), 10, get_move)
	var magikarp: Dictionary = runtime.pokemon_rules.create_pokemon_instance(catalog.get_species("MAGIKARP"), 10, get_move)
	runtime.session.add_item("fire_stone", 2) # stone bag
	runtime.session.add_item("old_rod", 1) # rod bag
	runtime.session.repel_steps = 25 # Phase 4 counter
	# The v4 pastures surface rides the VALIDATED seam: a raw dict would be an orphan
	# pen — load faithfully relocates its mons to the campsite and erases the key, so
	# a stable save->reload->save round-trip requires a REAL pen (build + deposit).
	var party_before: Array = _runner.swap_party(runtime, ["MACHOP", "CALYREX", "RHYPERIOR"], 30) # the fence resolver's capability witnesses (the breed_flow precedent)
	var pen_site := Vector2i.ZERO
	var built: Dictionary = {"reason": "no tree pen site scanned"}
	var scan_from: Vector2i = _player().tile_position
	for _attempt in range(24): # terrain is the seed's choice: scan onward until a site's fence ring is FULLY placeable
		var candidate := Sites.find_feature_pen_site(runtime._world_gen, scan_from, PEN_SCAN_RADIUS, "tree") # the GENERATOR, not the view: post-new_game the view's own generator instance still mirrors the boot world, and build_pen reads the generator — siting must validate the same world the build does
		if candidate == Vector2i.ZERO:
			break
		Sites.grant_pen_materials(runtime)
		runtime.session.add_item("hard_stone", 64) # desert-band pens: the fence shell costs hard_stone, never log/soil
		built = Sites.build_pen(runtime, candidate)
		if bool(built.get("ok", false)):
			pen_site = candidate; break
		Sites.demolish_pen(runtime, candidate) # the partial ring returns to the bag; next candidate
		scan_from = candidate
	_ensure(pen_site != Vector2i.ZERO, "pastures: no buildable tree pen site within %d rings (%s)" % [PEN_SCAN_RADIUS, str(built.get("reason", ""))])
	if pen_site != Vector2i.ZERO:
		Phase5.invalidate_pen_cache(runtime)
		_ensure(not Phase5.pen_key_for(runtime, pen_site + Vector2i.RIGHT).is_empty(), "pastures: the built pen did not flood around the feature")
		_runner.teleport_player(_world(), _player(), runtime, pen_site + Vector2i.RIGHT) # pen INTERIOR: deposit scans Manhattan-1 for a pen tile (the fence-Z stand spot serves withdrawals, not deposits)
		runtime.session.party.append(eevee) # the deposit seam takes a party index...
		var deposited: Dictionary = runtime.breeding_runtime.deposit_to_nearest_pen(runtime.session.party.size() - 1)
		_ensure(bool(deposited.get("ok", false)), "pastures: the pen deposit was refused (%s)" % str(deposited.get("reason", "")))
	runtime.session.campsite_pokemon.append(eevee.duplicate(true)) # deposit pair...
	runtime.session.campsite_pokemon.append(magikarp.duplicate(true))
	runtime.retrieve_campsite_mon(0) # ...then one withdraw through the runtime seam


func _payload(runtime) -> Dictionary:
	return runtime.session.to_save_payload(runtime._world_gen.overrides_for_save(), runtime._world_gen.placements_for_save())


# Recursive key-sorted canonicalization. "ts" and "version" are stripped so a version
# bump or a future timestamp never moves the comparison (the loader's version gate is
# exercised separately by the golden load).
func _canonicalize(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = (value as Dictionary).keys()
		keys.sort()
		var out: Dictionary = {}
		for key in keys:
			var key_str := str(key)
			if key_str == "version" or key_str == "ts":
				continue
			out[key_str] = _canonicalize((value as Dictionary)[key])
		return out
	if value is Array:
		var out_arr: Array = []
		for item in value as Array:
			out_arr.append(_canonicalize(item))
		return out_arr
	if value is float and is_finite(value) and value == floor(value):
		return int(value) # JSON.parse yields EVERY number as float: the canonical form is type-insensitive, so reload-floats (10.0 vs 10) never move the byte compare
	return value


func _canon_str(payload: Dictionary) -> String:
	return JSON.stringify(_canonicalize(payload))


func _check_golden(runtime, live_canon: String) -> void:
	if not FileAccess.file_exists(GOLDEN_PATH):
		_ensure(false, "golden: missing fixture at %s (run save_stability_update)" % GOLDEN_PATH)
		return
	var text := FileAccess.get_file_as_string(GOLDEN_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if not _ensure(parsed is Dictionary, "golden: the fixture is not a JSON object"):
		return
	_ensure(runtime._apply_loaded_payload(parsed as Dictionary), "golden: load(golden) failed — schema drift (run save_stability_update)")
	# THE ONE pinned guard change (Phase 7 Build 3): canonicalize the MIGRATED golden —
	# the live v5 save carries the three additive identity keys, so the un-migrated v4
	# fixture can never match it; migrate() is the witness under test here (line above
	# already exercised the true apply seam, which migrates first). The SAVE_VERSION
	# constant is passed EXPLICITLY (NO default-reliance — a future bump must move this
	# guard with it; SessionState is in scope via the SaveMigration preload chain).
	var canon_once := _canon_str(SaveMigration.migrate(parsed as Dictionary, SessionState.SAVE_VERSION))
	var reparsed: Variant = JSON.parse_string(canon_once)
	_ensure(reparsed is Dictionary and _canon_str(reparsed as Dictionary) == canon_once, "golden: the canonical form is not stable under re-canonicalization")
	_ensure(canon_once == live_canon, "golden: the committed fixture drifted from the live canonical save (run save_stability_update after an INTENTIONAL save change)")


func _write_golden(canon_text: String) -> void:
	var file = FileAccess.open(GOLDEN_PATH, FileAccess.WRITE)
	if not _ensure(file != null, "golden: cannot open %s for writing" % GOLDEN_PATH):
		return
	file.store_string(canon_text)
	file.close()


func _ensure(ok: bool, reason: String) -> bool:
	if not ok:
		_reasons.append(reason)
	return ok


# Recursive path list of every drift between the two canonical payloads, so a
# red names the FIELD, not just the fact (miss-002 cause-naming).
func _diff_paths(a: Variant, b: Variant, prefix := "") -> Array:
	var out: Array = []
	if a is Dictionary and b is Dictionary:
		for key in a:
			if not (b as Dictionary).has(key):
				out.append("%s%s: absent after reload" % [prefix, key])
			else:
				out.append_array(_diff_paths(a[key], b[key], "%s%s." % [prefix, key]))
		for key in b:
			if not (a as Dictionary).has(key):
				out.append("%s%s: new after reload" % [prefix, key])
	elif a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			out.append("%s: array size %d vs %d" % [prefix, (a as Array).size(), (b as Array).size()])
		for i in range(mini((a as Array).size(), (b as Array).size())):
			out.append_array(_diff_paths(a[i], b[i], "%s[%d]." % [prefix, i]))
	elif a != b:
		out.append("%s: %s vs %s" % [prefix.trim_suffix("."), str(a), str(b)])
	return out


func _world() -> Node: return _ctx["world"]
func _player() -> Node: return _ctx["player"]
func _runtime() -> Node: return _ctx["runtime"]
