extends RefCounted

# Sequences async turn playback for battle_view: the stage renders the
# pre-turn snapshot while each hit turn's animation plays, then the post-turn
# state renders — or, for a finished battle carrying turns (a KO blow), the
# animation plays before the view hides and battle_finished emits. Response
# state was applied synchronously by the caller; playback only defers visuals.

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
	if gen != generation:
		return
	view._set_animating(false)
	if finish.is_empty():
		view._render()
	else:
		view.visible = false
		view.battle_finished.emit(str(finish.get("outcome", "")), str(finish.get("message", "")))
