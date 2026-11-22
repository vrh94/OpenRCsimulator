## CLOUD-1 (2026-11-22): a field of 3D cumulus clouds for cloud surfing. The sky preset's renderer.cumulus_field
## places them (deterministically from the sky seed) on a jittered grid around the field: a flat base at base_m above
## the pilot's ground, tops up to top_m. Each cloud is a raymarched box (cumulus_field.gdshader) that the camera can
## fly around and through. Presentation only: this node never samples or changes flight physics.
extends Node3D

const SHADER_PATH := "res://render/weather/cumulus_field.gdshader"
const KEYS := ["layout_version", "base_m", "top_m", "spacing_m", "coverage", "radius_m", "min_width_m", "max_width_m"]
const MAX_CLOUDS := 400
const NOISE_SIZE := 48

static var _noise: ImageTexture3D

var _spec: Dictionary = {}
var _seed := -1
var _material: ShaderMaterial
var _clouds: Array[MeshInstance3D] = []
var _lighting: Array = []


## Errors for a renderer.cumulus_field record (empty when valid).
static func errors(spec: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if typeof(spec) != TYPE_DICTIONARY:
		out.append("cumulus_field must be an object")
		return out
	var record: Dictionary = spec
	if record.size() != KEYS.size() or not KEYS.all(func(key: String) -> bool: return record.has(key)):
		out.append("cumulus_field must contain exactly %s" % ", ".join(KEYS))
		return out
	for key: String in KEYS:
		if typeof(record[key]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(record[key])):
			out.append("cumulus_field %s must be a number" % key)
	if not out.is_empty():
		return out
	if int(record.layout_version) != 1:
		out.append("cumulus_field layout_version must be 1")
	if float(record.base_m) < 100.0 or float(record.top_m) > 6000.0 or float(record.top_m) - float(record.base_m) < 100.0:
		out.append("cumulus_field needs 100 m ≤ base_m, top_m ≤ 6000 m and at least 100 m of depth")
	if float(record.coverage) <= 0.0 or float(record.coverage) > 1.0:
		out.append("cumulus_field coverage must be above 0 and at most 1")
	if float(record.min_width_m) < 50.0 or float(record.max_width_m) < float(record.min_width_m) \
			or float(record.max_width_m) > float(record.spacing_m) * 1.5:
		out.append("cumulus_field widths must be 50 m or more, ordered, and at most 1.5 × spacing_m")
	if float(record.radius_m) < float(record.spacing_m) or float(record.radius_m) > 20000.0:
		out.append("cumulus_field radius_m must be from spacing_m to 20 km")
	elif pow(2.0 * float(record.radius_m) / float(record.spacing_m), 2.0) > float(MAX_CLOUDS) * 4.0:
		out.append("cumulus_field spacing is too dense for its radius")
	return out


## The clouds of a spec and seed: [{centre: Vector3, size: Vector3}] in the scene's frame (y up, metres above the
## pilot's ground). Pure and deterministic.
static func layout(spec: Dictionary, visual_seed: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not errors(spec).is_empty():
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([visual_seed, "cumulus-field-v1"])
	var spacing := float(spec.spacing_m)
	var radius := float(spec.radius_m)
	var cells := int(floor(radius / spacing))
	var base := float(spec.base_m)
	var depth := float(spec.top_m) - base
	for i in range(-cells, cells + 1):
		for j in range(-cells, cells + 1):
			# Draw every number for every cell so a cloud never depends on its neighbours being kept.
			var keep := rng.randf()
			var jitter := Vector2(rng.randf_range(-0.35, 0.35), rng.randf_range(-0.35, 0.35)) * spacing
			var width := lerpf(float(spec.min_width_m), float(spec.max_width_m), pow(rng.randf(), 1.4))
			var stretch := rng.randf_range(0.8, 1.25)
			var tall := rng.randf_range(0.5, 1.15)
			var base_shift := rng.randf_range(-0.03, 0.03) * depth
			var at := Vector2(i, j) * spacing + jitter
			if keep >= float(spec.coverage) or at.length() > radius or out.size() >= MAX_CLOUDS:
				continue
			var height := clampf(width * tall, 100.0, depth)
			out.append({centre = Vector3(at.x, base + base_shift + height * 0.5, at.y),
				size = Vector3(width * stretch, height, width / stretch)})
	return out


func configure(profile: Dictionary, visual_seed: int) -> void:
	var next: Dictionary = profile.get("renderer", {}).get("cumulus_field", {})
	if next == _spec and visual_seed == _seed:
		return
	_spec = next.duplicate(true)
	_seed = visual_seed
	_lighting = []
	for child: Node in get_children():
		child.free()
	_clouds.clear()
	visible = not _spec.is_empty() and errors(_spec).is_empty()
	if not visible:
		return
	_material = ShaderMaterial.new()
	_material.shader = load(SHADER_PATH) as Shader
	_material.set_shader_parameter("noise_texture", noise_texture())
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	for cloud: Dictionary in layout(_spec, _seed):
		var instance := MeshInstance3D.new()
		instance.name = "Cumulus%d" % _clouds.size()
		instance.mesh = box
		instance.material_override = _material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.position = cloud.centre
		instance.scale = cloud.size
		add_child(instance)
		_clouds.append(instance)


## Match the sky's light: lit cloud colour, the shaded underside, haze and the sun direction.
func update_visual(environment: Environment) -> void:
	if not visible or _material == null or environment == null or environment.sky == null:
		return
	var sky := environment.sky.sky_material as ShaderMaterial
	if sky == null:
		return
	var cloud_lin: Vector3 = sky.get_shader_parameter("cloud_lin")
	var haze_lin: Vector3 = sky.get_shader_parameter("haze_lin")
	var zenith_lin: Vector3 = sky.get_shader_parameter("zenith_lin")
	var sun_dir: Vector3 = sky.get_shader_parameter("sun_dir")
	var haze_density := environment.fog_density * 0.35
	var next := [cloud_lin, haze_lin, zenith_lin, sun_dir, haze_density]
	if next == _lighting:
		return
	_lighting = next
	_material.set_shader_parameter("cloud_lin", cloud_lin)
	_material.set_shader_parameter("shade_lin", cloud_lin * 0.26 + zenith_lin * 0.32 + haze_lin * 0.1)
	_material.set_shader_parameter("haze_lin", haze_lin)
	_material.set_shader_parameter("haze_density", haze_density)
	_material.set_shader_parameter("sun_dir", sun_dir if sun_dir.length() > 0.0 else Vector3.UP)


func cloud_count() -> int:
	return _clouds.size()


func snapshot() -> Dictionary:
	return {visible = visible, clouds = _clouds.size(), spec = _spec.duplicate(true), seed = _seed}


## The tiling noise the clouds are carved from: billowy inverted cellular fractal noise, built once per run.
static func noise_texture() -> ImageTexture3D:
	if _noise != null:
		return _noise
	var noise := FastNoiseLite.new()
	noise.seed = 4242
	noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	noise.frequency = 0.09
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	var images: Array[Image] = noise.get_seamless_image_3d(NOISE_SIZE, NOISE_SIZE, NOISE_SIZE, true, 0.15)
	_noise = ImageTexture3D.new()
	_noise.create(images[0].get_format(), NOISE_SIZE, NOISE_SIZE, NOISE_SIZE, false, images)
	return _noise
