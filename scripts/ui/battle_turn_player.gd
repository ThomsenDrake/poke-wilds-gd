extends RefCounted

# Sequences async turn playback for battle_view: the stage renders the
# pre-turn snapshot while each hit turn's animation plays, then the post-turn
# state renders — or, for a finished battle carrying turns (a KO blow), the
# animation plays, the post-KO snapshot and result message hold as the
# battle-clear beat, then the view hides and battle_finished emits. Response
# state was applied synchronously by the caller; playback only defers visuals.

const CLEAR_HOLD_FRAMES := 16

var generation := 0


func play(view: Node, turns: Array, previous_snapshot: Dictionary, finish := {}) -> void:
	generation += 1
	var gen := generation
	view._set_animating(true)
	var should_abort := func() -> bool: return gen != generation or not view.visible
	view._surface.render(previous_snapshot, "action", "", "")
	var played: Array = await view._animator.play_turns(turns, view._surface, view._surface.anim_actors(), should_abort)
	for stats in played:
		view._runtime().emit_trace("attack_animation_played", "BattleView", {"move_id": str(stats.get("move_id", "")), "anim_key": str(stats.get("anim_key", "")), "frames": int(stats.get("frames", 0)), "sound": bool(stats.get("sound", false)), "fallback": bool(stats.get("fallback", false))})
	if gen != generation or not is_instance_valid(view) or not view.is_inside_tree():
		return # a stale play — or a teardown-resumed one (the FrameTicker's final pulse unwinds playback at quit; never emit battle_finished mid-quit)
	if finish.is_empty():
		view._set_animating(false)
		view._render()
		return
	view._render()
	view._runtime().emit_trace("battle_clear_presented", "BattleView", {"outcome": str(finish.get("outcome", ""))})
	var tree := view.get_tree()
	for _i in range(CLEAR_HOLD_FRAMES):
		if gen != generation or tree == null or not is_instance_valid(view) or not view.is_inside_tree():
			return
		await tree.process_frame
	if gen != generation or not is_instance_valid(view) or not view.is_inside_tree():
		return
	view._set_animating(false)
	view.visible = false
	view.battle_finished.emit(str(finish.get("outcome", "")), str(finish.get("message", "")))
