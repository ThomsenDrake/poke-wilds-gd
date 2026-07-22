extends RefCounted

# Battle-half of the nav audit (see scripts/app/nav_audit.gd): drives the live
# battle view through the same handlers its input path uses — d-pad moves,
# activate (A), cancel (X) — and proves three contracts: every enabled option
# in the action/moves/item states is d-pad reachable (no orphans) with the
# view's selection id matching the layout model at each step; activating move
# row 0 performs the lead mon's actual first move (PP drops on row 0 only and
# the battle text names it); cancel from each submenu returns to the action
# state and RUN ends the battle — trap-tolerantly: a legitimate "Can't escape!"
# refusal is PROVEN, the trap expired, and escape re-proven, never a failure.
# Determinism pin: run() takes the caller's seed and calls seed_for_smoke so
# the wild draw and every battle roll are a pure function of (code, save, seed)
# — the house seeding convention, never the per-process wall-clock randomize().
# Fully synchronous: activations resolve through the runtime without frame waits.

const SmokeScenarioRunner := preload("res://scripts/runtime/smoke_scenario_runner.gd")

const DIRECTIONS := [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

var _runner = SmokeScenarioRunner.new()
var _failures: Array = []
var _options_checked := 0


func run(ctx: Dictionary, rng_seed: int) -> Dictionary:
	var runtime: Node = ctx["runtime"]
	runtime.seed_for_smoke(rng_seed)
	runtime.session.heal_party_full()
	_runner.refill_party_pp(runtime)
	if not _start_battle(ctx):
		_failures.append("battle: could not start a wild battle")
		return _result()
	var view: Node = ctx["battle_view"]
	_audit_state(view, "action")
	_audit_submenu(view, "fight", "moves")
	_audit_submenu(view, "item", "item")
	_audit_move_activation(view, ctx)
	if view.visible:
		_check_run_escape(view, ctx)
	elif _start_battle(ctx):
		_check_run_escape(ctx["battle_view"], ctx)
	else:
		_failures.append("battle: could not restart a battle for the run check")
	_set_battle(ctx, false)
	return _result()


func _result() -> Dictionary:
	return {"failures": _failures, "options_checked": _options_checked}


# Opens a submenu from the action state, audits its options, then proves X
# (cancel) returns to the action state.
func _audit_submenu(view: Node, selection: String, state: String) -> void:
	view._set_menu_state("action")
	view._selection = selection
	view._activate_selection()
	if view._menu_state != state:
		_failures.append("battle: %s did not open the %s state" % [selection, state])
		return
	_audit_state(view, state)
	view._cancel_selection()
	if view._menu_state != "action":
		_failures.append("battle: cancel from %s did not return to action" % state)


# BFS over the layout model from the first selectable option: every enabled
# option must be d-pad reachable (no orphans), and driving the live view
# along each model path must land on the predicted selection id.
func _audit_state(view: Node, state: String) -> void:
	var surface = view._surface
	var snapshot: Dictionary = view._snapshot
	var first: String = surface.first_selectable(state, snapshot)
	if first.is_empty():
		_failures.append("battle: %s state exposes no selectable option" % state)
		return
	var paths := {first: []}
	var queue: Array = [first]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for direction in DIRECTIONS:
			var next := _nav_step(surface, state, snapshot, current, direction)
			if next.is_empty() or next == current or paths.has(next):
				continue
			paths[next] = paths[current] + [direction]
			queue.append(next)
	for option in surface._layout.model(state, snapshot):
		var id := str(option.get("id", ""))
		if bool(option.get("enabled", false)) and not paths.has(id):
			_failures.append("battle: %s option '%s' is unreachable by d-pad" % [state, id])
	for id in paths.keys():
		view._set_menu_state(state)
		for direction in paths[id]:
			view._move_selection(direction)
		if view._selection != id:
			_failures.append("battle: %s nav to '%s' landed on '%s'" % [state, id, view._selection])
		else:
			_options_checked += 1
	view._set_menu_state(state)


# Mirrors battle_view._move_selection, including the moves-state horizontal
# fallback, so model paths predict live view behavior exactly.
func _nav_step(surface, state: String, snapshot: Dictionary, current: String, direction: Vector2i) -> String:
	var next: String = surface.next_selection(state, snapshot, current, direction)
	if state == "moves" and (next.is_empty() or next == current) and direction.x != 0:
		next = surface.next_selection(state, snapshot, current, Vector2i.DOWN if direction.x > 0 else Vector2i.UP)
	return next


# Activates move row 0: PP must drop on row 0 only and the battle text must
# name the lead mon's actual first move. Retries absorb flinch/faint turns
# where the player never acts; a battle that ends first is replaced once.
func _audit_move_activation(view: Node, ctx: Dictionary) -> void:
	var attempts := 0
	var restarts := 0
	while true:
		if not view.visible:
			restarts += 1
			if restarts > 1 or not _start_battle(ctx):
				break
			view = ctx["battle_view"]
			continue
		attempts += 1
		if attempts > 2:
			break
		var mon: Dictionary = view._snapshot.get("player_mon", {})
		var moves: Array = mon.get("moves", [])
		if moves.is_empty():
			_failures.append("battle: lead mon has no moves to activate")
			return
		var pp_before := _runner.move_pp_list(moves)
		var use_line := "%s used %s!" % [str(mon.get("name", "")), str(moves[0].get("name", moves[0].get("move_id", "")))]
		view._set_menu_state("moves")
		view._selection = "move_0"
		view._activate_selection()
		var spent := _runner.spent_move_rows(pp_before, _runner.move_pp_list(view._snapshot.get("player_mon", {}).get("moves", [])))
		if spent == [0] and view._message.contains(use_line):
			_options_checked += 1
			return
		if not spent.is_empty() or view._message.contains(use_line):
			_failures.append("battle: move_0 activated rows %s (message: %s)" % [str(spent), view._message])
			return
	_failures.append("battle: move_0 never performed the lead mon's first move")


# Total RUN contract: escape ends the battle when legal; while trapped the
# game's ONLY refusal is "Can't escape!" (battle_runtime.run_from_battle), so
# a still-visible view must carry exactly that text — proving the trap-refusal
# mechanic (new coverage) — then the trap is expired and escape re-proven. A
# legitimate in-game escape refusal can never be recorded as a suite failure.
func _check_run_escape(view: Node, ctx: Dictionary) -> void:
	view._set_menu_state("action")
	view._selection = "run"
	view._activate_selection()
	if not view.visible:
		_options_checked += 1
		return
	if not view._message.contains("Can't escape!"):
		_failures.append("battle: RUN left the view up without the trap refusal text (message: %s)" % view._message)
		return
	_options_checked += 1 # the refusal itself is proven contract behavior
	ctx["runtime"].battle_runtime._player_mon["trap_turns"] = 0
	view._selection = "run"
	view._activate_selection()
	if view.visible:
		_failures.append("battle: RUN did not end the battle after the trap expired")
	else:
		_options_checked += 1


func _start_battle(ctx: Dictionary) -> bool:
	var world: Node = ctx["world"]
	var player: Node = ctx["player"]
	var runtime: Node = ctx["runtime"]
	var wild_mon: Dictionary = runtime.generate_wild_encounter(player.tile_position, world.get_tile_biome(player.tile_position))
	if wild_mon.is_empty():
		return false
	_set_battle(ctx, true)
	ctx["message_box"].hide_message()
	ctx["music_router"].play_battle_track("wild")
	ctx["battle_view"].start_wild_battle(wild_mon)
	return ctx["battle_view"].visible


func _set_battle(ctx: Dictionary, active: bool) -> void:
	var callable: Callable = ctx.get("set_battle", Callable())
	if callable.is_valid():
		callable.call(active)
