extends RefCounted

# Initial bounded temporal flow adapters. Each adapter implements the generic
# temporal contract expected by TemporalFlowCapture:
#   phase() -> String
#   semantic() -> Dictionary
#   settle() -> bool
#   max_frames() -> int
# The scenario drives real input through the live battle view; the adapter only
# observes post-input phase/HP/animation state via a bounded frame window.

const SmokeTap := preload("res://scripts/app/smoke_tap.gd")

const BATTLE_ATTACK_ID := "battle_attack"
const BATTLE_CAPTURE_ID := "battle_capture"

# Keep the visual sweep isolated from the temporal lane: the capture contract
# must survive a bounded recording even if battle state advances.
class BattleAttackAdapter:
	extends RefCounted
	var _ctx: Dictionary = {}
	var _runtime: Node = null
	var _battle_view: Node = null
	var _phase := "before"
	var _start_enemy_hp := 0
	var _start_player_hp := 0
	var _frames := 0
	var _settled := false
	func setup(ctx: Dictionary) -> bool:
		_ctx = ctx
		_runtime = ctx.get("runtime")
		_battle_view = ctx.get("battle_view")
		return _runtime != null and _battle_view != null
	func phase() -> String:
		return _phase
	func semantic() -> Dictionary:
		var snap: Dictionary = _battle_view._snapshot if _battle_view != null and _battle_view.has_method("_snapshot") else {}
		# Fallback to runtime snapshot when view snapshot is not reachable.
		if snap.is_empty() and _runtime != null and _runtime.has_method("get_snapshot"):
			snap = _runtime.call("get_snapshot")
		var enemy_hp := int((snap.get("enemy_mon", {}) as Dictionary).get("current_hp", -1))
		var player_hp := int((snap.get("player_mon", {}) as Dictionary).get("current_hp", -1))
		return {"enemy_hp": enemy_hp, "player_hp": player_hp, "animating": bool(_battle_view.is_animating()) if _battle_view != null and _battle_view.has_method("is_animating") else false, "message": str(_battle_view._message) if _battle_view != null and " _message" in str(_battle_view) else ""}
	func settle() -> bool:
		return _settled
	func max_frames() -> int:
		return 120
	func _mark_started(enemy_hp: int, player_hp: int) -> void:
		_start_enemy_hp = enemy_hp
		_start_player_hp = player_hp
		_phase = "animating"
	func _mark_settled() -> void:
		_phase = "settled"
		_settled = true

class BattleCaptureAdapter:
	extends RefCounted
	var _ctx: Dictionary = {}
	var _runtime: Node = null
	var _battle_view: Node = null
	var _phase := "before"
	var _settled := false
	func setup(ctx: Dictionary) -> bool:
		_ctx = ctx
		_runtime = ctx.get("runtime")
		_battle_view = ctx.get("battle_view")
		return _runtime != null and _battle_view != null
	func phase() -> String:
		return _phase
	func semantic() -> Dictionary:
		return {"animating": bool(_battle_view.is_animating()) if _battle_view != null and _battle_view.has_method("is_animating") else false, "visible": bool(_battle_view.visible) if _battle_view != null else false}
	func settle() -> bool:
		return _settled
	func max_frames() -> int:
		return 150
	func _mark_capturing() -> void:
		_phase = "capturing"
	func _mark_settled() -> void:
		_phase = "settled"
		_settled = true
