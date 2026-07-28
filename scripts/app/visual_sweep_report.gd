extends RefCounted

# Reconcile + report for the MAIN visual sweep (extracted from visual_sweep_baselines.gd
# for the app line budget). push_error per drift/error/lost shot, else visual_sweep_passed.
# The baseline dir is SHARED with the satellite sweeps, so their baselines are foreign:
# the prune guard keeps updates from deleting them, this report guard from failing on them.

const VisualSweepBaselines := preload("res://scripts/app/visual_sweep_baselines.gd")
const RenderIntrospection := preload("res://scripts/app/render_introspection.gd")


func report(runtime, baselines, shots: Array, base_dir: String, mode: String, threshold_pct: float, dup_checked: int = 0, invalid: int = 0) -> void:
	var result: Dictionary = baselines.reconcile(shots, base_dir, mode, threshold_pct)
	var lost: Array = []
	for shot in result.get("uncaptured_baselines", []):
		if not VisualSweepBaselines._foreign_shot(str(shot)):
			lost.append(str(shot))
	if not bool(result.get("ok", false)) and lost.is_empty() and (result.get("mismatched", []) as Array).is_empty() and (result.get("errors", []) as Array).is_empty():
		result["ok"] = true # the differ tripped only on the other sweeps' baselines
	if not bool(result.get("ok", false)):
		var per_shot: Dictionary = result.get("per_shot", {})
		for shot in result.get("mismatched", []):
			push_error("Visual sweep drift on %s: %s%% of pixels changed (threshold %s%%)." % [shot, per_shot.get(shot, "?"), threshold_pct])
		for message in result.get("errors", []):
			push_error("Visual sweep diff error: %s" % message)
		for shot in lost:
			push_error("Visual sweep lost a shot: baseline %s has no capture this run." % shot)
		return
	runtime.emit_trace("visual_sweep_passed", "SmokeScenarios", {
		"shots": shots,
		"compared": int(result.get("compared", 0)),
		"mismatched": result.get("mismatched", []),
		"max_drift_pct": float(result.get("max_drift_pct", 0.0)),
		"mode": str(result.get("mode", mode)),
		"auto_update": bool(result.get("auto_update", false)),
		"updated": result.get("updated", []),
		"pruned": result.get("pruned", []),
		"threshold_pct": threshold_pct,
		"foreign_uncaptured": result.get("uncaptured_baselines", []),
		"base_dir": base_dir,
		"window": [VisualSweepBaselines.CANONICAL_WINDOW_SIZE.x, VisualSweepBaselines.CANONICAL_WINDOW_SIZE.y],
		"dup_checked": dup_checked,
		"invalid_captures": invalid,
		"sidecar_paths": shots.map(func(shot_name): return "%s/%s%s" % [base_dir, shot_name, RenderIntrospection.SIDECAR_SUFFIX])
	})
