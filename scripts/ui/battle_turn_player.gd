extends RefCounted

# Sequences async turn playback for battle_view: each action's message pages
# on the battle surface (one line per page, the MessageLabel budget), then that hit's
# animation plays, then leftover coda pages. For a finished battle the view
# hides after the coda and battle_finished emits a short outcome toast —
# never the full turn transcript (playtest #61: aggregated end-of-turn dump).

var generation := 0

const PAGE_LINES := 1
const PAGE_FRAMES := 24


func play(view: Node, turns: Array, previous_snapshot: Dictionary, finish := {}) -> void:
	generation += 1
	var gen := generation
	view._set_animating(true)
	var should_abort := func() -> bool: return gen != generation or not view.visible
	var full := str(finish.get("message", view._message)) if not finish.is_empty() else str(view._message)
	await _present(view, turns, previous_snapshot, full, should_abort)
	if gen != generation or not is_instance_valid(view) or not view.is_inside_tree():
		return # a stale play — or a teardown-resumed one (the FrameTicker's final pulse unwinds playback at quit; never emit battle_finished mid-quit)
	view._set_animating(false)
	if finish.is_empty():
		view._render()
	else:
		view.visible = false
		view.battle_finished.emit(str(finish.get("outcome", "")), _finish_toast(finish))


func _present(view: Node, turns: Array, previous_snapshot: Dictionary, full: String, should_abort: Callable) -> void:
	var prefix := _prefix_before_turns(full, turns)
	if not prefix.is_empty():
		await _show_pages(view, previous_snapshot, prefix, should_abort)
	for turn in turns:
		if should_abort.call():
			return
		var msg := str(turn.get("message", ""))
		if not msg.is_empty():
			await _show_pages(view, previous_snapshot, msg, should_abort)
		if should_abort.call() or not is_instance_valid(view):
			return
		if not bool(turn.get("hit", false)):
			continue
		var anim: Dictionary = turn.get("anim", {})
		if anim.is_empty():
			continue
		var stats: Dictionary = await view._animator.play(anim, view._surface, view._surface.anim_actors(), should_abort)
		if should_abort.call() or not is_instance_valid(view):
			return
		view._runtime().emit_trace("attack_animation_played", "BattleView", {"move_id": str(turn.get("move_id", "")), "anim_key": str(turn.get("anim_key", "")), "frames": int(stats.get("frames", 0)), "sound": bool(stats.get("sound", false)), "fallback": bool(stats.get("fallback", false))})
	if should_abort.call() or not is_instance_valid(view):
		return
	var coda := _remaining_after_turns(full, turns)
	if not coda.is_empty():
		await _show_pages(view, view._snapshot, coda, should_abort)


func _prefix_before_turns(full: String, turns: Array) -> String:
	for turn in turns:
		var msg := str(turn.get("message", ""))
		if msg.is_empty():
			continue
		var idx := full.find(msg)
		return "" if idx <= 0 else full.substr(0, idx).strip_edges()
	return ""


func _remaining_after_turns(full: String, turns: Array) -> String:
	var text := full
	var prefix := _prefix_before_turns(full, turns)
	if not prefix.is_empty() and text.begins_with(prefix):
		text = text.substr(prefix.length()).strip_edges()
	for turn in turns:
		var msg := str(turn.get("message", ""))
		if msg.is_empty():
			continue
		if text.begins_with(msg):
			text = text.substr(msg.length()).strip_edges()
		elif text.contains(msg):
			text = text.replace(msg, "").strip_edges()
	return text


func _show_pages(view: Node, snapshot: Dictionary, text: String, should_abort: Callable) -> void:
	var pages := _pages(text)
	var total := pages.size()
	var idx := 0
	for page in pages:
		if should_abort.call() or not is_instance_valid(view):
			return
		idx += 1
		view._surface.render(snapshot, "action", "", page)
		view._runtime().emit_trace("battle_message_shown", "BattleView", {"text": page, "page": idx, "pages": total})
		await _hold(view, should_abort)


func _pages(text: String) -> Array:
	var lines: Array = []
	for line in text.split("\n"):
		var stripped := str(line).strip_edges()
		if not stripped.is_empty():
			lines.append(stripped)
	var pages: Array = []
	var i := 0
	while i < lines.size():
		if i + 1 < lines.size() and PAGE_LINES > 1:
			pages.append("%s\n%s" % [lines[i], lines[i + 1]])
			i += 2
		else:
			pages.append(lines[i])
			i += 1
	return pages


func _hold(view: Node, should_abort: Callable) -> void:
	if view._animator == null or not is_instance_valid(view._surface):
		return
	var ticker: Node = view._animator._ticker_for(view._surface)
	for _i in range(PAGE_FRAMES):
		if ticker.exiting or should_abort.call():
			return
		await ticker.pulse


func _finish_toast(finish: Dictionary) -> String:
	var outcome := str(finish.get("outcome", ""))
	var full := str(finish.get("message", ""))
	var grant := _grant_suffix(full)
	match outcome:
		"defeat":
			return "You blacked out."
		"victory":
			return ("You won the battle." + grant).strip_edges()
		"escaped":
			return "Got away safely!"
		"caught", "caught_box_full":
			return (full.get_slice("\n", 0) + grant).strip_edges()
		_:
			return full.get_slice("\n", 0)


func _grant_suffix(full: String) -> String:
	var needle := "left behind a tablet"
	var idx := full.find(needle)
	if idx < 0:
		return ""
	var start := full.rfind("The ", idx)
	if start < 0:
		start = idx
	return " " + full.substr(start).strip_edges()
