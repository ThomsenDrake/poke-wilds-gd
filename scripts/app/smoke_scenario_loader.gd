extends Node

# Release packages never load the development scenario graph. Editor and
# headless-editor verification still resolve it on demand through the same
# Main-owned seam, keeping test-only parser dependencies out of player boot.

func run(scenario: String, context: Dictionary) -> void:
	if not OS.has_feature("editor"):
		return
	var runner := Node.new()
	var runner_script := load("res://scripts/app/smoke_scenarios.gd")
	if runner_script == null:
		push_error("Smoke scenario registry could not be loaded.")
		return
	runner.set_script(runner_script)
	add_child(runner)
	runner.run(scenario, context)
