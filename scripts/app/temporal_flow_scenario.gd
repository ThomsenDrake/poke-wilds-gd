extends Node

# Bounded temporal capture scenario dispatcher. Runs registered multi-frame
# flow adapters through TemporalFlowCapture and then through TemporalFlowChecks.
# Until battle/seam adapters land, this scenario emits a named temporal_failed
# with the structural reason rather than silently skipping a required flow.

const TemporalCapture := preload("res://scripts/app/temporal_flow_capture.gd")
const TemporalChecks := preload("res://scripts/app/temporal_flow_checks.gd")

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
	var reason := _run_flows(ctx)
	if reason.is_empty():
		runtime.emit_trace("temporal_flow_passed", "SmokeScenarios", {"scenario": scenario})
	else:
		var payload := {"failures": _failures, "scenario": scenario}
		runtime.emit_trace("temporal_flow_failed", "SmokeScenarios", payload)
		push_error("Temporal flow failed: %s" % "; ".join(PackedStringArray(_failures)))


func _fail(ctx: Dictionary, why: String) -> void:
	var runtime: Node = ctx.get("runtime")
	var scenario := str(ctx.get("scenario", "temporal_flow"))
	_failures.append(why)
	var payload := {"failures": _failures, "scenario": scenario}
	if runtime != null:
		runtime.emit_trace("temporal_flow_failed", "SmokeScenarios", payload)


func _run_flows(ctx: Dictionary) -> String:
	var runtime: Node = ctx.get("runtime")
	var viewport: Viewport = ctx.get("viewport")
	var base_dir: String = str(ctx.get("shot_dir", ".godot-smoke/temporal"))
	if runtime == null or viewport == null:
		_failures.append("temporal_flow: missing runtime/viewport context")
		return "missing context"
	var adapters: Array = _adapters(ctx)
	if adapters.is_empty():
		_failures.append("temporal_flow: no adapters registered")
		return "no adapters"
	var missing_ok := true
	for adapter in adapters:
		missing_ok = false
		var flow_id: String = str(adapter.get("flow_id", "temporal_flow"))
		if str(flow_id).is_empty():
			flow_id = "temporal_flow"
		var capture := TemporalCapture.new()
		var result: Dictionary = await capture.capture_flow(adapter.get("adapter"), runtime, viewport, base_dir, flow_id)
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


func _adapters(_ctx: Dictionary) -> Array:
	# Placeholder registry: battle_attack and battle_capture register here once
	# their animation/capture seams land. Until then, return no adapters so the
	# deterministic layer can prove the registration gap is loud (fail, not pass).
	return []


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
