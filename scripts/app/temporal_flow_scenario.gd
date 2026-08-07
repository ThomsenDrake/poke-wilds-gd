extends Node

# Bounded temporal capture scenario dispatcher. Runs registered multi-frame
# flow adapters through TemporalFlowCapture and then through TemporalFlowChecks.
# Battle attack + capture adapters ship first (Track A.2); missing adapters still
# fail loud (never a silent pass).

const TemporalCapture := preload("res://scripts/app/temporal_flow_capture.gd")
const TemporalChecks := preload("res://scripts/app/temporal_flow_checks.gd")
const TemporalAdapters := preload("res://scripts/app/temporal_battle_adapters.gd")

const TRACE_LOG_PATH := "user://logs/agent_trace.jsonl"
const WINDOWED_REQUIRED_MSG := "temporal_flow scenario requires a windowed transport (real pixels + frame_presented ordering)"

var _ctx: Dictionary = {}
var _failures: Array = []


func run(ctx: Dictionary) -> void:
	_ctx = ctx
	_failures = []
	if DisplayServer.get_name() == "headless":
		_fail(ctx, "headless")
		return
	await get_tree().create_timer(0.2).timeout
	var runtime: Node = ctx.get("runtime")
	var scenario := str(ctx.get("scenario", "temporal_flow"))
	var reason := await _run_flows(ctx)
	if reason.is_empty():
		runtime.emit_trace("temporal_flow_passed", "SmokeScenarios", {"scenario": scenario})
	else:
		var payload := {"failures": _failures, "scenario": scenario}
		runtime.emit_trace("temporal_flow_failed", "SmokeScenarios", payload)
		push_error("Temporal flow failed: %s" % "; ".join(PackedStringArray(_failures)))
	var set_battle: Callable = ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(false)


func _fail(ctx: Dictionary, why: String) -> void:
	var runtime: Node = ctx.get("runtime")
	var scenario := str(ctx.get("scenario", "temporal_flow"))
	_failures.append(why)
	var payload := {"failures": _failures, "scenario": scenario}
	if runtime != null:
		runtime.emit_trace("temporal_flow_failed", "SmokeScenarios", payload)


# The registered flows: prep opens the battle, trigger fires the move/ball, make
# is the adapter CONSTRUCTOR (setup is owned by _capture_one, exactly once).
# A function, not a const: GDScript consts cannot hold Callable expressions.
static func _flows() -> Array:
	return [
		{"id": TemporalAdapters.BATTLE_ATTACK_ID, "prep": TemporalAdapters.prepare_attack_battle,
			"trigger": TemporalAdapters.trigger_selected_move, "make": TemporalAdapters.BattleAttackAdapter.new},
		{"id": TemporalAdapters.BATTLE_CAPTURE_ID, "prep": TemporalAdapters.prepare_capture_battle,
			"trigger": TemporalAdapters.trigger_pokeball, "make": TemporalAdapters.BattleCaptureAdapter.new},
	]


func _run_flows(ctx: Dictionary) -> String:
	var runtime: Node = ctx.get("runtime")
	var viewport: Viewport = ctx.get("viewport")
	var base_dir: String = str(ctx.get("shot_dir", ".godot-smoke/temporal"))
	if runtime == null or viewport == null:
		_failures.append("temporal_flow: missing runtime/viewport context")
		return "missing context"
	for flow in _flows():
		await _close_battle(ctx) # no-op for the first flow; closes leftovers between flows
		var flow_id := str(flow["id"])
		var prep := str((flow["prep"] as Callable).call(ctx))
		if not prep.is_empty():
			_failures.append("temporal_flow %s prep: %s" % [flow_id, prep])
			return prep
		await get_tree().create_timer(0.15).timeout
		(flow["trigger"] as Callable).call(ctx)
		var fail := await _capture_one(ctx, (flow["make"] as Callable).call(), flow_id, base_dir)
		if not fail.is_empty():
			return fail
	return ""


func _close_battle(ctx: Dictionary) -> void:
	var set_battle: Callable = ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(false)
	await get_tree().create_timer(0.15).timeout


func _capture_one(ctx: Dictionary, adapter, flow_id: String, base_dir: String) -> String:
	var runtime: Node = ctx.get("runtime")
	var viewport: Viewport = ctx.get("viewport")
	if adapter == null or not bool(adapter.setup(ctx) if adapter.has_method("setup") else true):
		_failures.append("temporal_flow %s: adapter setup failed" % flow_id)
		return "adapter setup failed"
	var capture := TemporalCapture.new()
	var result: Dictionary = await capture.capture_flow(adapter, runtime, viewport, base_dir, flow_id)
	if not bool(result.get("ok", false)):
		for msg in (result.get("failures", []) as Array):
			_failures.append(str(msg))
		return str(_failures[0]) if not _failures.is_empty() else "capture failed"
	var manifest: Dictionary = _load_manifest(result.get("manifest_path", ""))
	var order_ok := TemporalChecks.monotonic_frames_ok(manifest)
	if not bool(order_ok.get("ok", false)):
		_failures.append("temporal_flow %s: %s" % [flow_id, str(order_ok.get("reason", ""))])
		return str(_failures[0])
	return ""


func _load_manifest(path: Variant) -> Dictionary:
	var p := str(path)
	if p.is_empty() or not FileAccess.file_exists(p):
		return {}
	var file := FileAccess.open(p, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}
