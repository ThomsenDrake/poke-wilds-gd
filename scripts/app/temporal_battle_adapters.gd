extends RefCounted

# Bounded temporal flow adapters (Track A.2). Each implements TemporalFlowCapture's
# contract: phase() / semantic() / settle() / max_frames(). The scenario opens the
# battle + triggers the move/ball BEFORE capture_flow; adapters only OBSERVE
# post-input phase/HP/animation and mark settled when the view goes idle after
# having seen an animating frame (or a hard frame budget).

const BATTLE_ATTACK_ID := "battle_attack"
const BATTLE_CAPTURE_ID := "battle_capture"


static func make_attack_adapter(ctx: Dictionary) -> BattleAttackAdapter:
	var adapter := BattleAttackAdapter.new()
	adapter.setup(ctx)
	return adapter


static func make_capture_adapter(ctx: Dictionary) -> BattleCaptureAdapter:
	var adapter := BattleCaptureAdapter.new()
	adapter.setup(ctx)
	return adapter


# Drive Charmander@10 vs Geodude@12 into the moves menu with EMBER selected —
# mirrors battle_anim_scenario so the temporal lane shares the same seed path.
static func prepare_attack_battle(ctx: Dictionary) -> String:
	var runtime: Node = ctx.get("runtime")
	var view: Node = ctx.get("battle_view")
	if runtime == null or view == null:
		return "missing runtime/battle_view"
	var catalog = runtime.get("catalog")
	var pokemon_rules = runtime.get("pokemon_rules")
	if catalog == null or pokemon_rules == null:
		return "runtime did not expose catalog/pokemon_rules"
	var get_move := Callable(catalog, "get_move")
	var lead: Dictionary = pokemon_rules.create_pokemon_instance(catalog.get_species("CHARMANDER"), 10, get_move)
	var ember_index := _move_index(lead, "EMBER")
	if ember_index < 0:
		return "built Charmander does not know EMBER"
	var wild_mon: Dictionary = pokemon_rules.create_pokemon_instance(catalog.get_species("GEODUDE"), 12, get_move)
	if wild_mon.is_empty():
		return "could not build wild Geodude"
	var session = runtime.get("session")
	var party_index: int = session.get_active_party_index() if session != null else -1
	if party_index < 0:
		return "no active party slot"
	session.set_party_member(party_index, lead)
	var set_battle: Callable = ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(true)
	var message_box = ctx.get("message_box")
	if message_box != null and message_box.has_method("hide_message"):
		message_box.hide_message()
	var music = ctx.get("music_router")
	if music != null and music.has_method("play_battle_track"):
		music.play_battle_track("wild")
	view.start_wild_battle(wild_mon)
	if not view.visible:
		return "battle view did not open"
	view._set_menu_state("moves")
	view._selection = "move_%d" % ember_index
	return ""


static func trigger_selected_move(ctx: Dictionary) -> void:
	var view: Node = ctx.get("battle_view")
	if view != null and view.has_method("_activate_selection"):
		view._activate_selection()


# Capture path: open a wild battle against a low-HP mon with balls in bag, then
# the scenario activates the ball select. Adapter settles when the view closes
# or stops animating after a capturing phase.
static func prepare_capture_battle(ctx: Dictionary) -> String:
	var runtime: Node = ctx.get("runtime")
	var view: Node = ctx.get("battle_view")
	if runtime == null or view == null:
		return "missing runtime/battle_view"
	var catalog = runtime.get("catalog")
	var pokemon_rules = runtime.get("pokemon_rules")
	if catalog == null or pokemon_rules == null:
		return "runtime did not expose catalog/pokemon_rules"
	var get_move := Callable(catalog, "get_move")
	var lead: Dictionary = pokemon_rules.create_pokemon_instance(catalog.get_species("MACHOP"), 20, get_move)
	# Full-HP low catch-rate target: a guaranteed catch has NO turns to animate;
	# a FAILED catch plays the ball-shake turns + counterattack this lane records.
	var wild_mon: Dictionary = pokemon_rules.create_pokemon_instance(catalog.get_species("GEODUDE"), 12, get_move)
	if wild_mon.is_empty():
		return "could not build wild GEODUDE"
	var session = runtime.get("session")
	var party_index: int = session.get_active_party_index() if session != null else -1
	if party_index < 0:
		return "no active party slot"
	session.set_party_member(party_index, lead)
	session.add_item("poke_ball", 5)
	var set_battle: Callable = ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(true)
	var message_box = ctx.get("message_box")
	if message_box != null and message_box.has_method("hide_message"):
		message_box.hide_message()
	var music = ctx.get("music_router")
	if music != null and music.has_method("play_battle_track"):
		music.play_battle_track("wild")
	view.start_wild_battle(wild_mon)
	if not view.visible:
		return "battle view did not open"
	return ""


# Drive capture through the battle VIEW (item menu -> poke_ball ->
# _activate_selection -> _apply_response) so the turn player actually animates.
# Calling runtime.use_pokeball() directly discards the response and leaves the
# view idle — the adapter would then "capture" static frames.
static func trigger_pokeball(ctx: Dictionary) -> void:
	var view: Node = ctx.get("battle_view")
	if view == null:
		return
	view._set_menu_state("item")
	view._selection = "poke_ball"
	if view.has_method("_activate_selection"):
		view._activate_selection()


static func _move_index(mon: Dictionary, move_id: String) -> int:
	var moves: Array = mon.get("moves", [])
	for i in range(moves.size()):
		if str(moves[i].get("move_id", "")) == move_id:
			return i
	return -1


class BattleAttackAdapter:
	extends RefCounted
	# Settle only after an OBSERVED animating frame followed by idle, and never
	# before MIN_FRAMES — a 1-frame vacuous capture (trigger silently failed)
	# must not read as a passed flow.
	const MIN_FRAMES := 3
	var _runtime: Node = null
	var _viewport: Viewport = null
	var _battle_view: Node = null
	var _phase := "before"
	var _saw_animating := false
	var _settled := false
	var _frames := 0
	func setup(ctx: Dictionary) -> bool:
		_runtime = ctx.get("runtime")
		_viewport = ctx.get("viewport")
		_battle_view = ctx.get("battle_view")
		_phase = "animating"
		_saw_animating = false
		return _runtime != null and _viewport != null and _battle_view != null
	func phase() -> String:
		return _phase
	func semantic() -> Dictionary:
		var snap: Dictionary = {}
		if _battle_view != null and "_snapshot" in _battle_view:
			snap = _battle_view._snapshot if _battle_view._snapshot is Dictionary else {}
		var enemy_hp := int((snap.get("enemy_mon", {}) as Dictionary).get("current_hp", -1))
		var player_hp := int((snap.get("player_mon", {}) as Dictionary).get("current_hp", -1))
		var animating := bool(_battle_view.is_animating()) if _battle_view != null and _battle_view.has_method("is_animating") else false
		if animating:
			_saw_animating = true
			_phase = "animating"
		elif _saw_animating and _frames >= MIN_FRAMES:
			_phase = "settled"
			_settled = true
		return {"enemy_hp": enemy_hp, "player_hp": player_hp, "animating": animating, "phase": _phase, "saw_animating": _saw_animating}
	func settle() -> bool:
		return _settled
	func max_frames() -> int:
		# A full exchange (move + counter) settles ~frame 124 on the FrameTicker
		# pulse (one process frame each); 120 was too tight. 160 covers it with
		# headroom while keeping per-frame PNG capture inside the wall-clock budget.
		return 160
	func on_frame(_frame) -> void:
		_frames += 1
		semantic() # refresh settle from live view each frame


class BattleCaptureAdapter:
	extends RefCounted
	# Settle requires an OBSERVED animating frame (the ball throw) then idle, or
	# the view closing on a finished capture — never a no-animation vacuous pass.
	const MIN_FRAMES := 3
	var _runtime: Node = null
	var _viewport: Viewport = null
	var _battle_view: Node = null
	var _phase := "capturing"
	var _settled := false
	var _frames := 0
	var _saw_animating := false
	func setup(ctx: Dictionary) -> bool:
		_runtime = ctx.get("runtime")
		_viewport = ctx.get("viewport")
		_battle_view = ctx.get("battle_view")
		return _runtime != null and _viewport != null and _battle_view != null
	func phase() -> String:
		return _phase
	func semantic() -> Dictionary:
		var visible := bool(_battle_view.visible) if _battle_view != null else false
		var animating := bool(_battle_view.is_animating()) if _battle_view != null and _battle_view.has_method("is_animating") else false
		if animating:
			_saw_animating = true
		# Settle only once the throw animated and the view went idle/closed.
		if _frames >= MIN_FRAMES and _saw_animating and (not visible or not animating):
			_phase = "settled"
			_settled = true
		else:
			_phase = "capturing"
		return {"animating": animating, "visible": visible, "phase": _phase, "saw_animating": _saw_animating}
	func settle() -> bool:
		return _settled
	func max_frames() -> int:
		# Ball throw + catch resolve animate on the FrameTicker pulse like attack.
		return 160
	func on_frame(_frame) -> void:
		_frames += 1
		semantic()
