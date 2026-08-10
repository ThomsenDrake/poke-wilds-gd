@tool
extends EditorDebuggerPlugin

signal event_line(record: Dictionary, raw: String)

const AgentTracePanel := preload("agent_trace_panel.gd")
const CAPTURE := "agent_trace"
const MESSAGE_EVENT := "agent_trace:event"

var _tabs := {}


func _setup_session(session_id: int) -> void:
	var panel := AgentTracePanel.new()
	panel.name = "Agent Trace"
	var session := get_session(session_id)
	session.add_session_tab(panel)
	_tabs[session_id] = panel
	# The editor frees session tabs when the session stops; only drop the ref.
	session.stopped.connect(_on_session_stopped.bind(session_id))


func _has_capture(capture: String) -> bool:
	return capture == CAPTURE


func _capture(message: String, data: Array, session_id: int) -> bool:
	if message != MESSAGE_EVENT or data.is_empty():
		return false
	var raw := str(data[0])
	var parsed: Variant = JSON.parse_string(raw)
	var record: Dictionary = parsed if parsed is Dictionary else {}
	var panel = _tabs.get(session_id)
	if is_instance_valid(panel):
		panel.ingest(record, raw)
	event_line.emit(record, raw)
	return true


func _on_session_stopped(session_id: int) -> void:
	_tabs.erase(session_id)
