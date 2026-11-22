extends RefCounted

const ADAPTERS: Array = [
	preload("res://landscapes/club_field/landscape.gd"),
	preload("res://landscapes/green_paradise/landscape.gd"),
	preload("res://landscapes/triglav_tamar/landscape.gd"),
	preload("res://landscapes/kamnik_duplica/landscape.gd"),
]

const DEFAULT_ID: String = "club_field"


static func ids() -> Array[String]:
	var ordered: Array[String] = []
	for adapter in ADAPTERS:
		ordered.append(str(adapter.ID))
	return ordered


static func has(id: String) -> bool:
	return _adapter(id) != null


static func entry(id: String) -> Dictionary:
	var adapter: Variant = _adapter(id)
	if adapter == null:
		return {}
	var out := {id = adapter.ID, name = adapter.DISPLAY_NAME, field_path = adapter.FIELD_PATH}
	# A landscape whose distant terrain lies beyond the default camera far plane names its own (metres).
	if "CAMERA_FAR_M" in adapter:
		out.camera_far_m = float(adapter.CAMERA_FAR_M)
	return out


## The flight camera's far plane on a landscape: the default unless the landscape needs to see farther.
static func camera_far_m(id: String, default_far_m: float) -> float:
	return maxf(default_far_m, float(entry(id).get("camera_far_m", 0.0)))


## `rc_track` (RC-TRACK) reaches only the club field, the one landscape whose geometry carries the circuit.
static func build(id: String, field: Dictionary, lighting: Dictionary = {}, rc_track: Dictionary = {}) -> Node3D:
	var adapter: Variant = _adapter(id)
	if adapter == null:
		return null
	return adapter.build(field, lighting, rc_track) if _takes_rc_track(id, rc_track) else adapter.build(field, lighting)


## Builders that support checkpoints yield on the main thread; simple landscapes retain their normal builder.
static func build_staged(id: String, field: Dictionary, lighting: Dictionary, checkpoint: Callable,
		rc_track: Dictionary = {}) -> Node3D:
	var adapter: Variant = _adapter(id)
	if adapter == null:
		return null
	if adapter.has_method("build_staged"):
		if _takes_rc_track(id, rc_track):
			return await adapter.build_staged(field, lighting, checkpoint, rc_track)
		return await adapter.build_staged(field, lighting, checkpoint)
	var begin := Time.get_ticks_usec()
	var result: Node3D = adapter.build(field, lighting)
	if result != null: result.set_meta("field_build_ms", (Time.get_ticks_usec() - begin) / 1000.0)
	return result


static func collision_world(id: String, field: Dictionary, rc_track: Dictionary = {}) -> Dictionary:
	var adapter: Variant = _adapter(id)
	if adapter != null:
		return adapter.collision_world(field, rc_track) if _takes_rc_track(id, rc_track) else adapter.collision_world(field)
	return {
		ok = false,
		world = {},
		errors = PackedStringArray(["landscape: unknown id '%s'" % id]),
	}


static func _takes_rc_track(id: String, rc_track: Dictionary) -> bool:
	return not rc_track.is_empty() and id == DEFAULT_ID


static func _adapter(id: String) -> Variant:
	for adapter in ADAPTERS:
		if str(adapter.ID) == id:
			return adapter
	return null
