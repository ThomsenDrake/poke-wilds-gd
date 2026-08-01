extends Node

# World-gen AUDIT scenario (spec: bootstrap-and-overworld.md; the comprehensive world-gen
# workflow). Runs the audit (world_gen_audit_runner) across a fixed seed list + the live
# catalog and emits the miss-002-symmetric world_gen_audit_passed / world_gen_audit_failed
# {failures} over the ENFORCING tier ONLY (structural invariants that hold today: disc
# determinism, ring admission, pool legendary/egg no-leak, landmark-in-extent, spawn-disc
# exclusion, spawn reachability). Every future-fix gap — biome blending, BST↔depth spawn
# coherence, LAVA/dungeon site availability, unreachable anchors — rides the warning-tier
# world_gen_audit_advisory event, which NEVER gates (it is the punch-list for the later fix
# slices). The audit consumes NO rng (pure function of code + catalog + seeds), so it is
# deterministic by construction and is deliberately NOT a double-run consumer. Writes a JSON
# findings artifact best-effort; the curated docs/generated/world-gen-audit-findings.md is the
# committed human-readable companion.

const WorldGenAuditRunner := preload("res://scripts/runtime/world_gen_audit_runner.gd")

const AUDIT_SEEDS := [1337, 1, 42, 20260101, 31337, 999983, 2026072907, 2026072913, 2026073001]
const ARTIFACT_PATH := "res://.godot-smoke/world-gen-audit-findings.json"

var _ctx: Dictionary = {}

func run(ctx: Dictionary) -> void:
	_ctx = ctx
	await get_tree().create_timer(0.2).timeout
	var runtime = ctx["runtime"]
	var findings: Dictionary = WorldGenAuditRunner.run_audit(AUDIT_SEEDS, runtime.catalog.species, runtime._biome_encounters)
	_write_artifact(findings)
	var failures: Array = findings.get("enforcing_failures", [])
	if bool(findings.get("ok", false)):
		runtime.emit_trace("world_gen_audit_passed", "SmokeScenarios", {
			"seeds": AUDIT_SEEDS.size(), "tiles_checked": int(findings.get("tiles_checked", 0)),
			"advisory_count": int(findings.get("advisory_count", 0))})
	else:
		runtime.emit_trace("world_gen_audit_failed", "SmokeScenarios", {"failures": failures, "seeds": AUDIT_SEEDS.size()})
		push_error("WorldGenAudit failed: %s" % "; ".join(PackedStringArray(failures.slice(0, 8))))
		runtime.warn("WorldGenAudit", "World-gen enforcing invariants regressed.", {"failures": failures})
	# Advisory tier — warning-tier, NEVER gates: the future-fix punch-list (kinds + count here;
	# the full findings ride the JSON artifact + the committed findings .md).
	var kinds: Array = []
	for item in findings.get("advisory_findings", []):
		kinds.append("%s.%s" % [str((item as Dictionary).get("goal", "")), str((item as Dictionary).get("kind", ""))])
	runtime.emit_trace("world_gen_audit_advisory", "SmokeScenarios", {
		"advisory_count": int(findings.get("advisory_count", 0)), "kinds": kinds})
	runtime.warn("WorldGenAudit", "World-gen advisory findings (future-fix punch-list; never gates).", {
		"advisory_count": int(findings.get("advisory_count", 0)), "kinds": kinds})


# Best-effort JSON artifact (the committed findings .md is curated from this). _json_safe
# coerces any Vector2i a family let through into [x, y] so JSON.stringify cannot choke.
func _write_artifact(findings: Dictionary) -> void:
	var dir := DirAccess.open("res://.godot-smoke")
	if dir == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot-smoke"))
	var file := FileAccess.open(ARTIFACT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_json_safe(findings), "  "))
	file.close()


func _json_safe(value: Variant) -> Variant:
	if value is Vector2i:
		return [value.x, value.y]
	if value is Vector2:
		return [value.x, value.y]
	if value is Dictionary:
		var out: Dictionary = {}
		for k in value:
			out[str(k)] = _json_safe(value[k])
		return out
	if value is Array:
		var arr: Array = []
		for item in value:
			arr.append(_json_safe(item))
		return arr
	return value
