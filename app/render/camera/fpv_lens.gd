# CAM-12 / FPV-3: the onboard camera's wide-angle lens (docs/plans/camera-views.md §5.3). The rig still places the
# flight camera (audio listener, lens effects, glare and every other camera consumer read it unchanged); while the
# lens is on, a SubViewport in the same World3D renders that camera's pose with a supersampled rectilinear lens,
# fpv_lens.gdshader warps it to the chosen projection on a full-screen layer below every overlay, and the main
# viewport skips its own 3D pass (Viewport.disable_3d stops rendering only, not listening or picking) so the scene is
# drawn once. Not hint_screen_texture: that copy is taken before transparent geometry, so the propeller blur disc and
# smoke would be missing (plan §5.3). Presentation only.
extends Node

const SHADER := preload("res://render/camera/fpv_lens.gdshader")

## "rectilinear" is the plain camera: no warp, and no extra viewport unless a video effect needs the pass. The others
## are radial lens projections.
const MODELS: Array[String] = ["rectilinear", "barrel", "fisheye"]
const DEFAULT_MODEL := "barrel"
## Rectilinear source limits: its half-height in tan units is capped at tan(60°) (120° vertical); rays beyond fall
## into the rim, as a real FPV lens's image circle leaves the sensor corners dark at its widest settings.
const SOURCE_TAN_CAP := 1.7320508075688772
## Supersampling: enough for the source to keep the centre at the output's own pixel density, within the plan's
## 1.2–1.5× budget; wider lenses beyond the cap trade a little centre sharpness. FPV-4 video quality sets the cap
## (per axis; the pixel budget is its square); "low" renders below the picture size, like a soft analog camera.
const SUPERSAMPLE_MIN := 1.0
const SUPERSAMPLE_MAX := 1.5
const QUALITY := { low = 0.75, medium = 1.25, high = 1.5 }
const DEFAULT_QUALITY := "high"
## FPV-4 video noise: grain amplitude (share of the signal) per setting.
const NOISE := { off = 0.0, low = 0.04, medium = 0.08, high = 0.16 }
const DEFAULT_NOISE := "off"
## FPV-4 motion blur: the share of a frame the virtual shutter stays open; larger turns between frames are cuts.
const SHUTTER := 0.5
const BLUR_CUT_DEG := 30.0
const THETA_LIMIT := deg_to_rad(89.0)
const VIGNETTE := 0.25
## Below every overlay and lens-stack layer, above the (disabled) 3D picture.
const LAYER := -100

var model := DEFAULT_MODEL
var supersample_max := SUPERSAMPLE_MAX
var quality := DEFAULT_QUALITY
var noise := DEFAULT_NOISE
var motion_blur := false
## FPV-7: how broken the analog picture is (0 clean … 1 lost), from the route's VideoLink.
var breakup := 0.0
var active := false
var _previous_basis := Basis()
var _has_previous := false
var _viewport: SubViewport
var _camera: Camera3D
var _layer: CanvasLayer
var _rect: ColorRect
var _material: ShaderMaterial
var _main_viewport: Viewport
var _main_3d_was_disabled := false
var _last := {}


## Lens geometry for a horizontal FOV `hfov_deg` (edge of the picture), picture aspect `aspect` (width / height) and
## projection `lens`. Units: half picture height. Returns {focal, theta_corner, tan_extent (Vector2), source_vfov_deg,
## supersample, source_scale (Vector2: source size over the picture size per axis)}.
## The source covers the picture corners where it can; its height is capped (SOURCE_TAN_CAP) but its width always
## reaches the picture's left and right edges, so a very wide lens loses only its corners to the rim. The source keeps
## the centre at the picture's own pixel density, within a pixel budget of supersample_cap² times the picture.
static func geometry(lens: String, hfov_deg: float, aspect: float, supersample_cap := SUPERSAMPLE_MAX) -> Dictionary:
	var a := aspect if aspect > 0.0 else 16.0 / 9.0
	var half := deg_to_rad(clampf(hfov_deg, 1.0, 170.0)) * 0.5
	var focal := a / radius_at(lens, half, 1.0)
	var r_corner := sqrt(a * a + 1.0)
	var theta_corner := minf(theta_at(lens, r_corner, focal), THETA_LIMIT)
	var corner_tan := tan(theta_corner) / r_corner # per half-height of the picture, along each axis
	var ty := minf(corner_tan, SOURCE_TAN_CAP)
	var tx := minf(a * corner_tan, maxf(a * ty, tan(half)))
	var source_aspect := tx / ty
	# Centre density: one picture half-height spans 1/focal tan units near the axis; the source's spans ty / scale.
	var cap := maxf(supersample_cap, 0.25)
	var lowest := minf(SUPERSAMPLE_MIN, cap)
	var supersample := clampf(focal * ty, lowest, cap)
	var width_scale := supersample * source_aspect / a
	if supersample * width_scale > cap * cap:
		supersample = maxf(lowest * a / source_aspect, cap / sqrt(source_aspect / a))
		width_scale = supersample * source_aspect / a
	return { focal = focal, theta_corner = theta_corner, tan_extent = Vector2(tx, ty),
		source_vfov_deg = rad_to_deg(2.0 * atan(ty)), supersample = supersample,
		source_scale = Vector2(width_scale, supersample) }


## Ray angle from the axis (rad) for an output radius r (half-height units).
static func theta_at(lens: String, r: float, focal: float) -> float:
	match lens:
		"barrel": return 2.0 * atan(r / (2.0 * focal))
		"fisheye": return r / focal
	return atan(r / focal)


## Output radius for a ray angle θ: the lens model itself (used by tests to check the warp).
static func radius_at(lens: String, theta: float, focal: float) -> float:
	match lens:
		"barrel": return 2.0 * focal * tan(theta * 0.5)
		"fisheye": return focal * theta
	return focal * tan(theta)


## Where an output point p (half-height units, y up) samples the rectilinear source, in tan units; the mirror of
## fpv_lens.gdshader. Returns {inside, s (Vector2 tan units), theta}.
static func source_point(lens: String, p: Vector2, geo: Dictionary) -> Dictionary:
	var r := p.length()
	var theta := theta_at(lens, r, float(geo.focal))
	if theta >= THETA_LIMIT:
		return { inside = false, s = Vector2.INF, theta = theta }
	var s := tan(theta) * p / r if r > 1e-6 and lens != "rectilinear" else p / float(geo.focal)
	var extent: Vector2 = geo.tan_extent
	return { inside = absf(s.x) <= extent.x and absf(s.y) <= extent.y, s = s, theta = theta }


## Builds the lens nodes under `parent`, inactive.
func build(parent: Node) -> void:
	name = "FpvLens"
	_viewport = SubViewport.new()
	_viewport.name = "FpvLensViewport"
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.audio_listener_enable_3d = false # the flight camera stays the only listener
	_viewport.handle_input_locally = false
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.name = "FpvLensCamera"
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.current = true # the lens viewport's only camera
	_viewport.add_child(_camera)
	_layer = CanvasLayer.new()
	_layer.name = "FpvLensLayer"
	_layer.layer = LAYER
	_layer.visible = false
	add_child(_layer)
	_rect = ColorRect.new()
	_rect.name = "FpvLensPicture"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("source", _viewport.get_texture())
	_rect.material = _material
	_layer.add_child(_rect)
	parent.add_child(self)


## Whether the lens pass is needed at all: a warp, or a video effect that only the pass can draw.
func needs_pass() -> bool:
	return model != "rectilinear" or float(NOISE.get(noise, 0.0)) > 0.0 or motion_blur or breakup > 0.001


## FPV-4 video settings; unknown values are ignored.
func set_video(quality_mode: String, noise_mode: String, blur: bool) -> void:
	if QUALITY.has(quality_mode):
		quality = quality_mode
		supersample_max = float(QUALITY[quality_mode])
	if NOISE.has(noise_mode):
		noise = noise_mode
	motion_blur = blur


## FPV-4: the camera-space rotation from a ray's direction now to its direction SHUTTER of a frame earlier, given the
## camera basis now and one frame earlier; identity for a cut (a turn over BLUR_CUT_DEG between frames).
static func blur_rotation(now: Basis, before: Basis) -> Basis:
	var relative := Quaternion((before.orthonormalized().inverse() * now.orthonormalized()).orthonormalized())
	if rad_to_deg(relative.get_angle()) > BLUR_CUT_DEG:
		return Basis.IDENTITY
	return Basis(Quaternion.IDENTITY.slerp(relative, SHUTTER))


## Per frame, after the rig (and any crash focus) placed `flight_camera`. on: the onboard lens picture is showing.
## hfov_deg: the onboard horizontal FOV; clock_s: the presentation clock that drives the grain (deterministic).
func update(flight_camera: Camera3D, on: bool, hfov_deg: float, clock_s := 0.0) -> void:
	var want := on and needs_pass() and is_instance_valid(flight_camera) and flight_camera.is_inside_tree()
	if want != active:
		_set_active(want, flight_camera)
	if not active:
		return
	var main := flight_camera.get_viewport()
	var size := Vector2(main.get_visible_rect().size)
	if size.x < 1.0 or size.y < 1.0:
		return
	var aspect := size.x / size.y
	var geo := geometry(model, hfov_deg, aspect, supersample_max)
	var scale: Vector2 = geo.source_scale
	var wanted := Vector2i(maxi(1, roundi(size.x * scale.x)), maxi(1, roundi(size.y * scale.y)))
	if _viewport.size != wanted:
		_viewport.size = wanted
	_copy_render_settings(main)
	_camera.global_transform = flight_camera.global_transform
	_camera.fov = float(geo.source_vfov_deg)
	_camera.near = flight_camera.near
	_camera.far = flight_camera.far
	_camera.cull_mask = flight_camera.cull_mask
	_camera.environment = flight_camera.environment
	_camera.attributes = flight_camera.attributes
	_camera.compositor = flight_camera.compositor
	var now := flight_camera.global_transform.basis
	var rotation := blur_rotation(now, _previous_basis) if motion_blur and _has_previous else Basis.IDENTITY
	_previous_basis = now
	_has_previous = true
	_material.set_shader_parameter("blur_on", motion_blur and not rotation.is_equal_approx(Basis.IDENTITY))
	_material.set_shader_parameter("blur_rotation", rotation)
	_material.set_shader_parameter("noise_amount", float(NOISE.get(noise, 0.0)))
	_material.set_shader_parameter("noise_time", clock_s)
	_material.set_shader_parameter("breakup", breakup if breakup > 0.001 else 0.0)
	_material.set_shader_parameter("picture_size", size)
	var key := [model, geo.focal, aspect]
	if key != _last.get("key", []):
		_material.set_shader_parameter("aspect", aspect)
		_material.set_shader_parameter("focal", float(geo.focal))
		_material.set_shader_parameter("model", {barrel = 0, fisheye = 1}.get(model, 2))
		_material.set_shader_parameter("tan_extent", geo.tan_extent)
		_material.set_shader_parameter("theta_corner", float(geo.theta_corner))
		_material.set_shader_parameter("vignette", VIGNETTE)
		_last = { key = key, geometry = geo }


func set_model(lens: String) -> void:
	if lens in MODELS:
		model = lens


## Evidence for captures and tests.
func evidence() -> Dictionary:
	return { active = active, model = model, viewport_size = _viewport.size if _viewport != null else Vector2i.ZERO,
		geometry = _last.get("geometry", {}), quality = quality, noise = noise, motion_blur = motion_blur, breakup = breakup }


func _set_active(on: bool, flight_camera: Camera3D) -> void:
	active = on
	_layer.visible = on
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if on:
		_main_viewport = flight_camera.get_viewport()
		_main_3d_was_disabled = _main_viewport.disable_3d
		_main_viewport.disable_3d = true
	elif is_instance_valid(_main_viewport):
		_main_viewport.disable_3d = _main_3d_was_disabled
		_main_viewport = null
		_last = {}
	_has_previous = false # entering or leaving is a cut: no blur across it


## The lens viewport renders like the main one: the same anti-aliasing and filtering. Temporal upscalers keep their
## history on the main viewport, so the lens viewport renders at native scale; its supersampling replaces them.
func _copy_render_settings(main: Viewport) -> void:
	# Colour space: an HDR-2D main viewport composes in linear light, so the source must hand over a linear float
	# texture too (as the lake reflection does); an sRGB source there would be encoded twice and look washed out.
	if _viewport.use_hdr_2d != main.use_hdr_2d:
		_viewport.use_hdr_2d = main.use_hdr_2d
	if _viewport.msaa_3d != main.msaa_3d:
		_viewport.msaa_3d = main.msaa_3d
	var aa := main.screen_space_aa
	if _viewport.screen_space_aa != aa:
		_viewport.screen_space_aa = aa
	if _viewport.use_debanding != main.use_debanding:
		_viewport.use_debanding = main.use_debanding
	if _viewport.anisotropic_filtering_level != main.anisotropic_filtering_level:
		_viewport.anisotropic_filtering_level = main.anisotropic_filtering_level
	if _viewport.mesh_lod_threshold != main.mesh_lod_threshold:
		_viewport.mesh_lod_threshold = main.mesh_lod_threshold
	if _viewport.positional_shadow_atlas_size != main.positional_shadow_atlas_size:
		_viewport.positional_shadow_atlas_size = main.positional_shadow_atlas_size


func _exit_tree() -> void:
	if active and is_instance_valid(_main_viewport):
		_main_viewport.disable_3d = _main_3d_was_disabled
