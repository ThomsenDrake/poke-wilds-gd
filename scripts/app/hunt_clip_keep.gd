extends RefCounted

# Windowed hunt keep path: per-run inbox + quarantine-tier clip writes.
# Lives under scripts/app so it may call SnapshotCapture.

const SnapshotCapture := preload("res://scripts/app/snapshot_capture.gd")
const PlaytestBot := preload("res://scripts/runtime/playtest_bot.gd")

const INBOX_ROOT := "res://.godot-smoke/hunt-inbox"
const FORWARD_FRAMES := 4
const CADENCE_MS := 30000


var run_id: String = ""
var run_dir: String = ""
var rows: Array = []
var keep_seq: int = 0
var last_cadence_ms: int = 0
var spatial := PlaytestBot.new()


func begin_run(runtime: Node) -> void:
	run_id = _timestamp()
	run_dir = "%s/%s" % [INBOX_ROOT, run_id]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	rows = []
	keep_seq = 0
	last_cadence_ms = Time.get_ticks_msec()
	_write_index()
	_write_runs_list()
	runtime.emit_trace("hunt_run_started", "HuntSoak", {"run_id": run_id, "dir": run_dir})


func note_step(runtime: Node, world, player) -> int:
	var before: int = spatial.spatial_violations
	spatial.note_spatial_step(player, world)
	return spatial.spatial_violations - before


func keep_coded(host: Node, runtime: Node, viewport: Viewport, trigger: String, place: Dictionary) -> void:
	await _keep(host, runtime, viewport, "coded", trigger, place)


func maybe_cadence_still(host: Node, runtime: Node, viewport: Viewport, place: Dictionary) -> void:
	var now: int = Time.get_ticks_msec()
	if now - last_cadence_ms < CADENCE_MS:
		return
	last_cadence_ms = now
	await _keep(host, runtime, viewport, "still", "cadence_still", place)


func _keep(host: Node, runtime: Node, viewport: Viewport, tag: String, trigger: String, place: Dictionary) -> void:
	keep_seq += 1
	var keep_id := "%s-%02d" % [tag, keep_seq]
	var clip_dir := "%s/%s" % [run_dir, keep_id]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(clip_dir))
	var frames: Array = []
	if viewport != null and DisplayServer.get_name() != "headless":
		var snap := SnapshotCapture.new()
		for i in range(FORWARD_FRAMES):
			var shot := "%s/%03d" % [keep_id, i]
			var save_path := "%s/%03d.png" % [clip_dir, i]
			var result: Dictionary = await snap.capture(runtime, viewport, shot, {"save_path": save_path, "metadata": {"hunt_keep": keep_id, "trigger": trigger}})
			if str(result.get("kind", "")) == "":
				frames.append(save_path)
			await host.get_tree().process_frame
	var row := {
		"id": keep_id,
		"tag": tag,
		"trigger": trigger,
		"seed": int(place.get("seed", 0)),
		"place": place,
		"clip_path": clip_dir,
		"frames": frames,
		"ts_msec": Time.get_ticks_msec(),
	}
	if tag != "still":
		rows.append(row)
		runtime.emit_trace("quarantine_finding", "HuntSoak", {"kind": "hunt_clip", "tag": tag, "trigger": trigger, "keep_id": keep_id})
		runtime.emit_trace("hunt_clip_kept", "HuntSoak", {"keep_id": keep_id, "tag": tag, "trigger": trigger})
	else:
		rows.append(row)
	_write_index()


func finish(runtime: Node) -> void:
	_write_index()
	runtime.emit_trace("hunt_soak_finished", "HuntSoak", {
		"run_id": run_id,
		"keeps": rows.size(),
		"coded": _count_tag("coded"),
		"model": _count_tag("model"),
		"stills": _count_tag("still"),
	})


func _count_tag(tag: String) -> int:
	var n := 0
	for row in rows:
		if str(row.get("tag", "")) == tag:
			n += 1
	return n


func _write_index() -> void:
	var ranked: Array = rows.duplicate()
	ranked.sort_custom(func(a, b):
		var ta := 0 if str(a.get("tag", "")) == "coded" else (1 if str(a.get("tag", "")) == "model" else 2)
		var tb := 0 if str(b.get("tag", "")) == "coded" else (1 if str(b.get("tag", "")) == "model" else 2)
		if ta != tb:
			return ta < tb
		return int(a.get("ts_msec", 0)) < int(b.get("ts_msec", 0))
	)
	var payload := {"run_id": run_id, "keeps": ranked}
	var path := "%s/index.json" % run_dir
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(payload))
	file.close()


func _write_runs_list() -> void:
	var root_abs := ProjectSettings.globalize_path(INBOX_ROOT)
	var runs: Array = []
	var dir := DirAccess.open(root_abs)
	if dir != null:
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if dir.current_is_dir() and not name.begins_with("."):
				runs.append(name)
			name = dir.get_next()
		dir.list_dir_end()
	runs.sort()
	runs.reverse()
	var file := FileAccess.open("%s/runs.json" % INBOX_ROOT, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"runs": runs, "latest": run_id}))
	file.close()


func _timestamp() -> String:
	var t := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d-%02d%02d%02d" % [t.year, t.month, t.day, t.hour, t.minute, t.second]
