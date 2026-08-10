@tool
extends EditorPlugin

const AgentTraceDebugger := preload("agent_trace_debugger.gd")
const AgentTraceActivity := preload("agent_trace_activity.gd")

var _debugger: EditorDebuggerPlugin
var _activity: Control


func _enter_tree() -> void:
	_activity = AgentTraceActivity.new()
	_activity.name = "Agent Trace"
	add_control_to_bottom_panel(_activity, "Agent Trace")
	_debugger = AgentTraceDebugger.new()
	_debugger.event_line.connect(_activity.ingest)
	add_debugger_plugin(_debugger)


func _exit_tree() -> void:
	if _debugger != null:
		remove_debugger_plugin(_debugger)
		_debugger = null
	if _activity != null:
		remove_control_from_bottom_panel(_activity)
		_activity.queue_free()
		_activity = null
