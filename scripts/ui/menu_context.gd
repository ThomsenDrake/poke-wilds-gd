extends RefCounted

# StartMenu context resolution, EXTRACTED from start_menu.gd (both at the 220 ui budget):
# resolves a raw context Dictionary of Callables, backfilling runtime-backed keys from the
# /root/GameRuntime autoload (party/bag accessors, save_game, new_game, campsite hold/
# retrieve, deposit gates) and session-backed keys from runtime.session. Keys with no
# fallback (get_species, get_item, ...) degrade to an invalid Callable so the hosted screens
# still open gracefully. Pure wiring — no game state, no domain.

static func resolve(raw: Dictionary, runtime_methods: Dictionary, session_methods: Dictionary, runtime: Node) -> Dictionary:
	var resolved := raw.duplicate()
	if runtime == null:
		return resolved
	for key in runtime_methods:
		if not accessor(resolved, key).is_valid():
			resolved[key] = node_accessor(runtime, runtime_methods[key])
	for key in session_methods:
		if not accessor(resolved, key).is_valid():
			resolved[key] = node_accessor(runtime.get("session"), session_methods[key])
	return resolved

static func accessor(context: Dictionary, key: String) -> Callable:
	var value: Variant = context.get(key, Callable())
	return value if value is Callable else Callable()

static func node_accessor(target: Variant, method: String) -> Callable:
	if target is Object and (target as Object).has_method(method):
		return Callable(target, method)
	return Callable()

static func call_context(context: Dictionary, key: String, args: Array = []) -> Variant:
	var callable := accessor(context, key)
	if not callable.is_valid():
		return null
	return callable.callv(args)
