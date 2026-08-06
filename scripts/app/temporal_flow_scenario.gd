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


func _run_flows(ctx: Dictionary) -> String:
	var runtime: Node = ctx.get("runtime")
	var viewport: Viewport = ctx.get("viewport")
	var base_dir: String = str(ctx.get("shot_dir", ".godot-smoke/temporal"))
	if runtime == null or viewport == null:
		_failures.append("temporal_flow: missing runtime/viewport context")
		return "missing context"
	# --- battle_attack ---
	var prep := TemporalAdapters.prepare_attack_battle(ctx)
	if not prep.is_empty():
		_failures.append("temporal_flow battle_attack prep: %s" % prep)
		return prep
	await get_tree().create_timer(0.15).timeout
	TemporalAdapters.trigger_selected_move(ctx)
	var attack := TemporalAdapters.make_attack_adapter(ctx)
	var attack_fail := await _capture_one(ctx, attack, TemporalAdapters.BATTLE_ATTACK_ID, base_dir)
	if not attack_fail.is_empty():
		return attack_fail
	# Close any leftover battle before the capture flow.
	var set_battle: Callable = ctx.get("set_battle", Callable())
	if set_battle.is_valid():
		set_battle.call(false)
	await get_tree().create_timer(0.15).timeout
	# --- battle_capture ---
	prep = TemporalAdapters.prepare_capture_battle(ctx)
	if not prep.is_empty():
		_failures.append("temporal_flow battle_capture prep: %s" % prep)
		return prep
	await get_tree().create_timer(0.15).timeout
	TemporalAdapters.trigger_pokeball(ctx)
	var capture := TemporalAdapters.make_capture_adapter(ctx)
	var capture_fail := await _capture_one(ctx, capture, TemporalAdapters.BATTLE_CAPTURE_ID, base_dir)
	if not capture_fail.is_empty():
		return capture_fail
	return ""


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
