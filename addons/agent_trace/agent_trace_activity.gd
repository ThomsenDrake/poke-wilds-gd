@tool
extends VBoxContainer

const MAX_ROWS := 500
const PAYLOAD_LIMIT := 200
const PASS_COLOR := "#7bd88f"
const FAIL_COLOR := "#f47067"
const MARK_COLOR := "#8b949e"

var _rows: Array[String] = []
var _passed := 0
var _failed := 0
var _tally: Label
var _output: RichTextLabel


func _init() -> void:
	var toolbar := HBoxContainer.new()
	var title := Label.new()
	title.text = "Scenario activity (agent_trace stream)"
	toolbar.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(spacer)
	_tally = Label.new()
	toolbar.add_child(_tally)
	var clear_button := Button.new()
	clear_button.text = "Clear"
	clear_button.pressed.connect(_clear)
	toolbar.add_child(clear_button)
	add_child(toolbar)
	_output = RichTextLabel.new()
	_output.bbcode_enabled = true
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_output.scroll_following = true
	_output.selection_enabled = true
	add_child(_output)
	_update_tally()


func _ready() -> void:
	var mono := get_theme_font("source", "EditorFonts")
	if mono != null:
		_output.add_theme_font_override("normal_font", mono)


func ingest(record: Dictionary, _raw: String) -> void:
	var event := str(record.get("event", ""))
	if event.ends_with("_passed"):
		_passed += 1
		_add_row(PASS_COLOR, "PASS", event, record)
	elif event.ends_with("_failed"):
		_failed += 1
		_add_row(FAIL_COLOR, "FAIL", event, record)
	elif event == "smoke_scenario_dispatched":
		_add_row(MARK_COLOR, "RUN ", event, record)


func _add_row(color: String, tag: String, event: String, record: Dictionary) -> void:
	var payload := JSON.stringify(record.get("payload", {}))
	if payload.length() > PAYLOAD_LIMIT:
		payload = payload.left(PAYLOAD_LIMIT) + "..."
	var line := "[color=%s]%s  %s  %s[/color]" % [
		color, tag, _esc(event), _esc(payload)
	]
	_rows.append(line)
	if _rows.size() > MAX_ROWS * 2:
		_rows = _rows.slice(_rows.size() - MAX_ROWS)
		_rebuild()
	else:
		_output.append_text(line + "\n")
	_update_tally()


func _esc(text: String) -> String:
	return text.replace("[", "[lb]")


func _rebuild() -> void:
	_output.clear()
	for row in _rows:
		_output.append_text(row + "\n")


func _clear() -> void:
	_rows.clear()
	_passed = 0
	_failed = 0
	_output.clear()
	_update_tally()


func _update_tally() -> void:
	_tally.text = "%d passed / %d failed   " % [_passed, _failed]
