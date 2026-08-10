extends Node

# Assertion half of the legibility_soak agreement gate (the app 220-wall split;
# the new_game_flow_checks extraction precedent — the scenario file stays the
# driver). THREE agent-legibility surfaces must AGREE while the scenario drives
# the five agent-facing screens:
#   1. ui_tree dumps — each .godot-smoke/ui_tree/<screen>.json the scenario
#      writes parses, names its screen id, and every node entry carries
#      path/type/rect[4]; the list screens (title/menu/bag — the screens the
#      GBC widget library annotates, docs/references/accessibility.md) carry
#      the RowList cursor "Row N of M: <row text>" a11y_description exemplar
#      (gbc_widgets.gd / menu_list_stage.gd) plus a11y_name row labels.
#   2. Performance monitors — game/current_screen, read WHILE the screen is up
#      (never deferred — it reads live visibility), names the screen being
#      dumped, closing the "MANUALLY kept in sync" gap between
#      scripts/runtime/performance_monitors.gd and the dump ids;
#      game/party_size + game/world_seed are registered, readable, int-typed,
#      and agree with the runtime they probe.
#   3. Trace lifecycle — the driven transitions emit title_shown /
#      menu_opened / menu_closed / encounter_started / battle_finished on the
#      JSONL stream (the smoke_scenario_runner cursor probe).
# Every assertion funnels through expect(), which counts for the pass
# payload's checks field.

const UiTreeDumpWriter := preload("res://scripts/app/ui_tree_dump_writer.gd")

const OUT_DIR := UiTreeDumpWriter.OUT_DIR # the scenario's own dumps; the writer owns the one canonical artifact dir (strict-review F1)
const LIST_SCREENS: Array[String] = ["title", "menu", "bag"] # the RowList/Rows-annotated screens (party/battle carry no widget annotations)
const ROW_DESC_RE := "^Row \\d+ of \\d+: .+$" # the list cursor contract: "Row N of M: <row text>"
# The scenario's crafted battle fixture, mirrored here (single pin set per file,
# the new_game_flow_checks precedent).
const WILD_SPECIES := "GEODUDE"
const WILD_LEVEL := 12

var _ctx: Dictionary = {}
var _runner = null # the scenario's SmokeScenarioRunner, injected by run()
var _failures: Array = [] # shared with the parent scenario
var _count := 0 # every assertion, for the pass payload's checks field
var _row_re := RegEx.new()

func run(ctx: Dictionary, runner, failures: Array) -> void:
	_ctx = ctx
	_runner = runner
	_failures = failures
	_row_re.compile(ROW_DESC_RE)

# Surface 2 (interleaved): the live current_screen monitor must name the
# screen being dumped — read while the screen is up.
func monitor_agrees(screen_id: String) -> void:
	if not expect(Performance.has_custom_monitor(&"game/current_screen"), "monitors: game/current_screen is not registered"):
		return
	var actual: Variant = Performance.get_custom_monitor(&"game/current_screen")
	if expect(actual is String, "monitors: game/current_screen is %s, not a String" % type_string(typeof(actual))):
		expect(actual == screen_id, "monitors: game/current_screen reads '%s' while the %s screen is being dumped" % [actual, screen_id])

# Surface 2 (deferred): the scalar monitors are registered, readable,
# int-typed, and agree with the runtime they probe.
func scalars_readable() -> void:
	var runtime: Node = _ctx["runtime"]
	_check_scalar(&"game/party_size", runtime.session.party.size())
	_check_scalar(&"game/world_seed", runtime.get_world_seed())

func _check_scalar(monitor: StringName, want: int) -> void:
	if not expect(Performance.has_custom_monitor(monitor), "monitors: %s is not registered" % String(monitor)):
		return
	var value: Variant = Performance.get_custom_monitor(monitor)
	if expect(value is int, "monitors: %s is %s, not an int" % [String(monitor), type_string(typeof(value))]):
		expect(value == want, "monitors: %s reads %d, the runtime says %d" % [String(monitor), value, want])

# Surface 1 (deferred): the scenario's own dump for the screen parses and
# carries the contract fields; the list screens carry the a11y annotations.
func dump_file_ok(screen_id: String) -> void:
	var path := "%s/%s.json" % [OUT_DIR, screen_id]
	if not expect(FileAccess.file_exists(path), "%s: the scenario wrote no %s" % [screen_id, path]):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not expect(parsed is Dictionary, "%s: %s does not parse as a JSON object" % [screen_id, path]):
		return
	var dump: Dictionary = parsed
	expect(str(dump.get("screen", "")) == screen_id, "%s: the screen field reads '%s'" % [screen_id, str(dump.get("screen", ""))])
	expect(dump.get("cursor") is Dictionary, "%s: no cursor/selection object" % screen_id)
	var nodes: Variant = dump.get("nodes")
	if not expect(nodes is Array and not (nodes as Array).is_empty(), "%s: nodes is not a non-empty array" % screen_id):
		return
	expect(int(dump.get("node_count", -1)) == (nodes as Array).size(), "%s: node_count disagrees with the nodes array" % screen_id)
	var named := 0
	var cursor_desc := false
	for entry in nodes:
		if not expect(entry is Dictionary, "%s: a node entry is not an object" % screen_id):
			continue
		var shaped: bool = not str(entry.get("path", "")).is_empty() and not str(entry.get("type", "")).is_empty() \
			and entry.get("rect") is Array and (entry.get("rect") as Array).size() == 4
		if not expect(shaped, "%s: node '%s' lacks path/type/rect[4]" % [screen_id, str(entry.get("path", "?"))]):
			continue
		if not str(entry.get("a11y_name", "")).is_empty():
			named += 1
		if _row_re.search(str(entry.get("a11y_description", ""))) != null:
			cursor_desc = true
	if LIST_SCREENS.has(screen_id):
		expect(named > 0, "%s: no node carries an a11y_name (the row-label contract)" % screen_id)
		expect(cursor_desc, "%s: no node carries the Row N of M cursor a11y_description" % screen_id)

# Surface 3 (deferred): the driven transitions emitted their lifecycle events
# on the JSONL stream since the pre-drive cursor.
func lifecycle_traces_ok(cursor: int) -> void:
	expect(_runner.trace_log_has_since("title_shown", cursor), "traces: no title_shown since the drive began")
	expect(_runner.trace_log_has_since("menu_opened", cursor), "traces: no menu_opened since the drive began")
	expect(_runner.trace_log_has_since("menu_closed", cursor), "traces: no menu_closed since the drive began")
	expect(_runner.trace_log_has_since("encounter_started", cursor, {"species_id": WILD_SPECIES, "level": WILD_LEVEL}), "traces: no encounter_started for the crafted %s" % WILD_SPECIES)
	expect(_runner.trace_log_has_since("battle_finished", cursor), "traces: no battle_finished after the smoke escape")

func checks_run() -> int: return _count

func expect(ok: bool, label: String) -> bool: # counts + appends a labeled failure; returns ok for guard early-returns
	_count += 1
	if not ok:
		_failures.append(label)
	return ok
