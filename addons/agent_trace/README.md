# Agent Trace (editor plugin)

(the repo-wide agent surface — protocols, channels, and conventions this
plugin plugs into).

An in-editor viewer for the repo's existing trace stream. It visualizes the
JSONL trace contract documented in [docs/references/trace-events.md](../../docs/references/trace-events.md)
— the same records `scripts/core/trace_logger.gd` prints to stdout and appends
to `user://logs/agent_trace.jsonl`. It is protocol-based and agent-vendor-neutral:
anything that runs the game from the editor (a human, a scenario lane, any
agent harness) produces the same stream; the plugin just renders it.

## Enabling

The plugin ships **disabled by default** (`project.godot` is intentionally not
modified). Opt in per developer machine:

**Project Settings > Plugins > Agent Trace > Enable**

## What you get

- **Debugger tab "Agent Trace"** — one tab per debug session in the debugger
  bottom panel. A scrollable, monospace, auto-following list of the live trace
  records (`ts_msec`, `event`, `source`, compact JSON payload), with a
  substring filter field and Pause/Clear controls. Pause freezes the view while
  the stream keeps buffering; Clear empties the session buffer.
- **Bottom panel "Agent Trace"** — an activity log of agent/scenario-driven
  runs tailing the same stream: `*_passed` events in green, `*_failed` in red,
  `smoke_scenario_dispatched` run markers dimmed, plus a running pass/fail
  tally. Both surfaces are kept (not folded into one) so the raw stream and the
  scenario verdicts can be visible at the same time.

Run the game from the editor (F5) with the plugin enabled and both surfaces
fill live. With the plugin disabled or no debugger attached, nothing changes.

## Message contract

Game side (`scripts/core/trace_logger.gd`, additive only):

```gdscript
if EngineDebugger.is_active():
    EngineDebugger.send_message("agent_trace:event", [line])
```

- Message: `"agent_trace:event"` (capture prefix `agent_trace`).
- Payload: a one-element Array whose single entry is **one JSONL string** — a
  serialized `{event, ts_msec, source, payload}` record, exactly the line that
  was printed and appended to the log file.
- When `EngineDebugger.is_active()` is false (headless runs, scenario lanes,
  exports), the hook is a strict no-op and logger behavior is byte-identical
  to the pre-hook version.

Editor side: `agent_trace_debugger.gd` (an `EditorDebuggerPlugin`) declares the
`agent_trace` capture, parses each line back to a Dictionary, routes it to the
originating session's tab, and rebroadcasts it to the bottom-panel activity
log.

## Failure posture

The plugin is editor-only and never loads in game runs. The game-side hook is
guarded by `EngineDebugger.is_active()` and cannot break headless or scenario
runs; a malformed line degrades to being displayed raw rather than dropped.
