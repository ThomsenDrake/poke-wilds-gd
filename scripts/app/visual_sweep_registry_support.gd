extends RefCounted

# R3 registry helpers, extracted from visual_sweep_baselines.gd at the app-220 wall
# (check_architecture.py SCRIPT_LIMITS). The registry seed is the SINGLE source of truth for the
# captured world_seed: each satellite's crafted world_seed is single-sourced from SHOT_REGISTRY so
# the registry seed and the sidecar's crafted_state.world_seed (what the RED-tier seed-equality gate
# in run_playtests._sidecar_seed_equality_violations reads) agree BY CONSTRUCTION. A satellite that
# renders a DERIVED world (visual_sweep_world_chain) registers that derived value as its seed, so
# registry_seed_for() returns it verbatim and the gate still holds. The registry dict is passed in
# (visual_sweep_baselines.SHOT_REGISTRY) so this file does NOT preload baselines (no cycle).

# The registry seed for a sweep (0 when the sweep is unknown — a mis-wired caller, never a sidecar).
static func registry_seed_for(registry: Dictionary, sweep: String) -> int:
	return int((registry.get(sweep, {}) as Dictionary).get("seed", 0))


# A sweep's crafted state with its world_seed single-sourced from the registry; `base` supplies the
# party/bag/time_of_day. The sidecar stamps this dict verbatim (render_introspection.collect), so the
# captured seed IS the registry seed.
static func crafted_state_for(registry: Dictionary, sweep: String, base: Dictionary) -> Dictionary:
	var crafted: Dictionary = base.duplicate(true)
	crafted["world_seed"] = registry_seed_for(registry, sweep)
	return crafted
