extends RefCounted

# Generic bounded temporal capture lane (plan § Runtime and capture changes):
# per-process-frame bounded PNG sequence with timing/phase metadata.
# Reuses snapshot_capture.gd's capture contract so the new flow is a second
# specialized capture mode on top of the same readback/validity machinery.
# Future flows (title/creation, menus, crafting, overworld transitions) plug in
# by implementing TemporalAdapter; battle attack/capture ships first.

const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")

const MAX_FRAMES_DEFAULT := 120 # guard even for indefinite animations
const PROCESS_FRAME_BUDGET := 480 # hard cap: two full animation plays + settle, under the 600s lane timeout
const CAPTURE_SUBDIR := "temporal"

class TemporalFrame:
	var frame_index: int = 0
	var ts_msec: int = 0
	var trace_cursor: int = 0
	var phase: String = ""
	var semantic: Dictionary = {}
	var shot: String = ""
	var sidecar_path: String = ""
	var ok: bool = true


static func _shot_name(flow_id: String, index: int) -> String:
	return "%s_%03d.png" % [flow_id, index]


static func _manifest_path(base_dir: String, flow_id: String) -> String:
	return "%s/%s/%s_timeline.json" % [base_dir, CAPTURE_SUBDIR, flow_id]


# Captures one temporal flow. `adapter` must implement:
# - setup() -> Dictionary {runtime, viewport, world, player, battle_view?}
# - phase() -> String
# - semantic() -> Dictionary (flow-relevant values: move_id, hp, message, anim_key, overlay, menu)
# - settle() -> bool  (capture loop stops when true)
# - max_frames() -> int (optional, defaults to MAX_FRAMES_DEFAULT)
# - on_frame(frame: TemporalFrame) (optional hook)
#
# Returns {ok, flow_id, frames: [TemporalFrame], manifest_path, failures: [] }
func capture_flow(adapter, runtime: Node, viewport: Viewport, base_dir: String, flow_id: String) -> Dictionary:
	var failures: Array = []
	if adapter == null or runtime == null or viewport == null or base_dir.is_empty() or flow_id.is_empty():
		return {"ok": false, "flow_id": flow_id, "frames": [], "manifest_path": "", "failures": ["temporal capture: missing adapter/runtime/viewport/base_dir/flow_id"]}
	var max_frames := MAX_FRAMES_DEFAULT
	if adapter.has_method("max_frames"):
		max_frames = maxi(1, int(adapter.call("max_frames")))
	max_frames = mini(max_frames, PROCESS_FRAME_BUDGET)
	var flow_dir := "%s/%s" % [base_dir, CAPTURE_SUBDIR]
	var dir_ok := DirAccess.make_dir_recursive_absolute(flow_dir)
	if dir_ok != OK and not DirAccess.dir_exists_absolute(flow_dir):
		return {"ok": false, "flow_id": flow_id, "frames": [], "manifest_path": "", "failures": ["temporal capture: cannot create %s" % flow_dir]}
	var snapshots := SnapshotCapture.new()
	var frames: Array = []
	var settled := false
	for i in range(max_frames):
		var phase := str(adapter.call("phase")) if adapter.has_method("phase") else ""
		var semantic := (adapter.call("semantic") as Dictionary) if adapter.has_method("semantic") else {}
		var shot := _shot_name(flow_id, i)
		var meta := {
			"temporal": true,
			"flow_id": flow_id,
			"frame_index": i,
			"phase": phase,
			"semantic": semantic,
		}
		var result: Dictionary = await snapshots.capture(runtime, viewport, shot, {"save_path": "%s/%s" % [flow_dir, shot], "metadata": meta})
		var frame := TemporalFrame.new()
		frame.frame_index = i
		frame.ts_msec = int(result.get("trace_cursor", 0)) # keep the trace_cursor join key
		frame.trace_cursor = int(result.get("trace_cursor", 0))
		frame.phase = phase
		frame.semantic = semantic
		frame.shot = shot
		frame.sidecar_path = str(result.get("sidecar_path", ""))
		frame.ok = bool(result.get("ok", false))
		frames.append(frame)
		if not bool(result.get("ok", false)):
			failures.append("temporal capture: %s frame %d invalid (%s: %s)" % [flow_id, i, str(result.get("kind", "")), str(result.get("detail", ""))])
			break
		if adapter.has_method("on_frame"):
			adapter.call("on_frame", frame)
		if adapter.has_method("settle") and bool(adapter.call("settle")):
			settled = true
			break
		await Engine.get_main_loop().current_scene.get_tree().process_frame
	if failures.is_empty() and not settled:
		# Not an error yet: some flows are best-effort bounded captures (general multi-frame flow lane).
		# The adapter's checks (temporal_flow_checks) decide pass/fail; the manifest still records what was captured.
		pass
	var manifest := {
		"flow_id": flow_id,
		"frame_count": frames.size(),
		"frames": _frame_manifest(frames),
		"settled": settled,
		"max_frames": max_frames,
		"failures": failures,
	}
	var manifest_path := _manifest_path(base_dir, flow_id)
	var file := FileAccess.open(manifest_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(manifest))
		file.close()
	return {"ok": failures.is_empty(), "flow_id": flow_id, "frames": frames, "manifest_path": manifest_path, "failures": failures}


static func _frame_manifest(frames: Array) -> Array:
	var out: Array = []
	for f in frames:
		out.append({
			"index": int(f.frame_index),
			"shot": str(f.shot),
			"sidecar": str(f.sidecar_path),
			"phase": str(f.phase),
			"trace_cursor": int(f.trace_cursor),
			"semantic": f.semantic,
		})
	return out
