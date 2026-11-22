# CLOUD-1 (2026-11-22): the Cloud Surfing sky. The preset is the last in the catalog and validates; its
# renderer.cumulus_field is checked strictly; the layout is deterministic per sky seed, stays inside its radius, base
# and top, and keeps every cloud inside its own box; a World shows the 3D cumulus only for this sky, follows the sky's
# light, and hides them again for another sky. Presentation only: test_sky_checkpoint.gd covers that a sky choice never
# changes the flight.
# Run: godot --headless --path . --audio-driver Dummy --script res://tests/test_cumulus_field.gd
extends SceneTree

const SkyConfig := preload("res://environment/sky_appearance_config.gd")
const Atmosphere := preload("res://render/atmosphere.gd")
const WorldBuilder := preload("res://render/world/world.gd")
const CumulusField := preload("res://render/weather/cumulus_field.gd")

var _checks := 0
var _failures := 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%s %s %s" % ["ok  " if ok else "FAIL", label, detail])


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var spec := _catalog()
	if not spec.is_empty():
		_validation(spec)
		_layout(spec)
		await _world()
	print("cumulus field: %d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _catalog() -> Dictionary:
	var presets := SkyConfig.presets()
	var ids: Array = presets.map(func(p: Dictionary) -> String: return str(p.id))
	_check("the catalog keeps its nine skies in order and adds Cloud Surfing last",
		ids.slice(0, 9) == SkyConfig.EXPECTED_PRESET_IDS.slice(0, 9) and ids.back() == "cloud_surfing", str(ids))
	var checked: Dictionary = SkyConfig.validate(SkyConfig.for_preset("cloud_surfing"))
	_check("the Cloud Surfing sky validates", checked.get("ok", false), str(checked.get("errors", [])))
	if not checked.get("ok", false):
		return {}
	var spec: Dictionary = checked.profile.renderer.cumulus_field
	_check("its clouds have flat bases 600 m above the field", float(spec.base_m) == 600.0 and float(spec.top_m) > 1000.0)
	var others := true
	for p: Dictionary in presets:
		if p.id != "cloud_surfing":
			others = others and not p.renderer.has("cumulus_field")
	_check("no other sky has 3D cumulus", others)
	return spec


func _validation(spec: Dictionary) -> void:
	_check("the shipped field validates", CumulusField.errors(spec).is_empty())
	var cases := {
		"a missing key": _without(spec, "coverage"),
		"an extra key": _with(spec, "rain", 1.0),
		"another layout version": _with(spec, "layout_version", 2),
		"a base below 100 m": _with(spec, "base_m", 50.0),
		"a top above 6 km": _with(spec, "top_m", 7000.0),
		"zero coverage": _with(spec, "coverage", 0.0),
		"widths out of order": _with(spec, "min_width_m", float(spec.max_width_m) + 1.0),
		"a radius beyond 20 km": _with(spec, "radius_m", 25000.0),
		"a grid too dense for its radius": _with(spec, "spacing_m", 200.0),
		"a text number": _with(spec, "base_m", "600"),
	}
	for label: String in cases:
		_check("refused: %s" % label, not CumulusField.errors(cases[label]).is_empty())
	var profile: Dictionary = SkyConfig.validate(SkyConfig.for_preset("cloud_surfing")).profile.duplicate(true)
	profile.renderer.cumulus_field.layout_version = 2
	_check("the sky catalog refuses a bad cumulus field", not SkyConfig._validate_profile(profile).is_empty())


func _layout(spec: Dictionary) -> void:
	var a: Array[Dictionary] = CumulusField.layout(spec, 1253)
	var b: Array[Dictionary] = CumulusField.layout(spec, 1253)
	var c: Array[Dictionary] = CumulusField.layout(spec, 1254)
	_check("the layout is the same for the same sky seed", a == b and not a.is_empty(), "%d clouds" % a.size())
	_check("another seed moves the clouds", a != c)
	var inside := true
	var heights := true
	for cloud: Dictionary in a:
		var centre: Vector3 = cloud.centre
		var size: Vector3 = cloud.size
		inside = inside and Vector2(centre.x, centre.z).length() <= float(spec.radius_m)
		var base := centre.y - size.y * 0.5
		var depth := float(spec.top_m) - float(spec.base_m)
		heights = heights and base >= float(spec.base_m) - 0.031 * depth and base + size.y <= float(spec.top_m) + 0.031 * depth \
			and size.x >= float(spec.min_width_m) * 0.79 and size.x <= float(spec.max_width_m) * 1.26
	_check("every cloud lies within the field's radius", inside)
	_check("bases, tops and widths stay within the spec", heights)
	_check("the count stays within the budget", a.size() <= CumulusField.MAX_CLOUDS)
	var texture := CumulusField.noise_texture()
	_check("the tiling noise is one shared 3D texture", texture != null and texture == CumulusField.noise_texture()
		and texture.get_width() == CumulusField.NOISE_SIZE and texture.get_depth() == CumulusField.NOISE_SIZE)


func _world() -> void:
	_check("the Cloud Surfing sky installs", Atmosphere.configure_appearance(SkyConfig.for_preset("cloud_surfing"), [0.0, 0.0, 0.0], 0.0))
	var owner := Node3D.new()
	root.add_child(owner)
	var world: Dictionary = WorldBuilder.build(owner, {}, Callable(self, "_empty_field"), {"time_of_day": false}, {},
		{"field_lighting": "off", "campfire": false})
	var environment: Environment = world.environment
	var field := WorldBuilder.cumulus_field_node(environment) as CumulusField
	var expected := CumulusField.layout(SkyConfig.validate(SkyConfig.for_preset("cloud_surfing")).profile.renderer.cumulus_field, 1253)
	_check("the World builds the 3D cumulus for Cloud Surfing", field != null and field.visible
		and field.cloud_count() == expected.size(), "%d" % (field.cloud_count() if field != null else -1))
	if field == null:
		owner.free()
		return
	var first := field.get_child(0) as MeshInstance3D
	_check("each cloud is a box over its layout, casting no shadow", first.position == expected[0].centre
		and first.scale == expected[0].size and first.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	WorldBuilder.update(environment, 1.0)
	var sky := environment.sky.sky_material as ShaderMaterial
	var material := first.material_override as ShaderMaterial
	_check("the clouds take the sky's light and sun direction",
		material.get_shader_parameter("cloud_lin") == sky.get_shader_parameter("cloud_lin")
		and material.get_shader_parameter("sun_dir") == sky.get_shader_parameter("sun_dir"))
	Atmosphere.configure_appearance(SkyConfig.for_preset("fair_cumulus"), [0.0, 0.0, 0.0], 0.0)
	WorldBuilder.refresh_weather_appearance(environment, 2.0)
	_check("another sky hides them", not field.visible and field.cloud_count() == 0)
	Atmosphere.configure_appearance(SkyConfig.for_preset("cloud_surfing"), [0.0, 0.0, 0.0], 0.0)
	WorldBuilder.refresh_weather_appearance(environment, 3.0)
	_check("and choosing Cloud Surfing again brings the same clouds back", field.visible and field.cloud_count() == expected.size()
		and (field.get_child(0) as Node3D).position == expected[0].centre)
	owner.free()
	await process_frame


func _empty_field() -> void:
	pass


func _with(spec: Dictionary, key: String, value: Variant) -> Dictionary:
	var out := spec.duplicate(true)
	out[key] = value
	return out


func _without(spec: Dictionary, key: String) -> Dictionary:
	var out := spec.duplicate(true)
	out.erase(key)
	return out
