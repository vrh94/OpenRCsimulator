# CAM-17: the player's camera preferences, stored as optional keys of display.cfg [camera] (app_state/
# display_preferences.gd). Presentation only. Home flights receive them through main.gd/helicopter_main.gd
# `camera_preferences`; direct and automation routes never read them, so captures and traces keep their pictures.
extends RefCounted

const PilotCamera := preload("res://render/pilot_camera.gd")
const OnboardView := preload("res://render/camera/onboard_view.gd")
const FpvHead := preload("res://render/camera/fpv_head.gd")
const FpvOsdModel := preload("res://render/overlays/fpv_osd_model.gd")
const VideoLink := preload("res://render/camera/video_link.gd")

## The view a Home flight starts in (D1: the pilot view stays the default). "onboard" falls back to the pilot view on
## routes without an onboard mount (the helicopter).
const VIEWS: Array[String] = ["pilot", "chase", "onboard", "cockpit", "flyby", "orbit"]
## FPV-2: the onboard lens (horizontal FOV, uptilt, mount smoothing).
const FPV_FOVS: Array[int] = OnboardView.FOVS
const FPV_TILTS: Array[int] = OnboardView.TILTS
const FPV_SMOOTHING: Array[String] = ["off", "light", "medium"]
## FPV-3: the onboard lens projection (render/camera/fpv_lens.gd MODELS).
const FPV_LENSES: Array[String] = ["rectilinear", "barrel", "fisheye"]
## FPV-4: camera vibration, video noise and quality (render/camera/onboard_view.gd SHAKE, fpv_lens.gd NOISE/QUALITY).
const FPV_SHAKES: Array[String] = ["off", "low", "medium", "high"]
const FPV_NOISES: Array[String] = ["off", "low", "medium", "high"]
const FPV_QUALITIES: Array[String] = ["low", "medium", "high"]
## FPV-5: head tracking, head-look sensitivity and the servo gimbal (render/camera/fpv_head.gd). Gimbal axes are the
## radio's joystick axes as the controller setup numbers them (0…9), -1 for none.
const FPV_HEAD_TRACKING: Array[String] = FpvHead.TRACKING
const FPV_HEAD_SENSITIVITIES: Array[float] = FpvHead.SENSITIVITIES
const FPV_GIMBAL_AXES: Array[int] = [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
const FPV_GIMBAL_PAN_TRAVELS: Array[int] = FpvHead.PAN_TRAVELS
const FPV_GIMBAL_TILT_TRAVELS: Array[int] = FpvHead.TILT_TRAVELS
const FPV_GIMBAL_SPEEDS: Array[String] = FpvHead.SERVO_SPEED_NAMES
## FPV-6: the fixed-wing OSD style and its elements (render/overlays/fpv_osd_model.gd).
const FPV_OSD_STYLES: Array[String] = FpvOsdModel.STYLES
const FPV_OSD_ELEMENTS: Array[String] = FpvOsdModel.ELEMENTS
## FPV-7: the analog video link and its transmitter power (render/camera/video_link.gd).
const FPV_LINKS: Array[String] = VideoLink.MODES
const FPV_VTX_POWERS: Array[int] = VideoLink.POWERS_MW
## The pilot view's widest vertical FOV (deg), which the auto-zoom narrows from. 50° stays the default until CAM-22;
## about 31° is orthoscopic on a 27-inch 16:9 screen seen from 60 cm (CAM-AUD-2026-10-24).
const FOVS: Array[int] = [30, 35, 40, 45, 50, 55, 60, 70]
## Multipliers of the orbit's mouse and stick turn rate, and of the chase boom.
const SENSITIVITIES: Array[float] = [0.5, 0.75, 1.0, 1.5, 2.0]
const CHASE_DISTANCES: Array[float] = [0.6, 0.8, 1.0, 1.25, 1.5]
## CAM-18 magnifier inset modes (mirrors render/camera/magnifier.gd MODES).
const MAGNIFIER_MODES: Array[String] = ["off", "auto", "on"]
## CAM-06/06b/28 pilot aids: off (today's picture) until the pilot chooses them in CAM-22.
const DEFAULTS := {
	"camera_view": "pilot",
	"camera_fov": 50,
	"camera_auto_zoom": true,
	"camera_zoom_law": "constant",
	"camera_horizon_bias": false,
	"camera_overhead_smoothing": false,
	"camera_magnifier": "off",
	"camera_chase_distance": 1.0,
	"camera_sensitivity": 1.0,
	"camera_invert_y": false,
	"camera_fpv_fov": int(OnboardView.DEFAULT_HFOV_DEG),
	"camera_fpv_tilt": int(OnboardView.DEFAULT_TILT_DEG),
	"camera_fpv_smoothing": OnboardView.DEFAULT_SMOOTHING,
	"camera_fpv_lens": "barrel",
	"camera_fpv_shake": "off",
	"camera_fpv_noise": "off",
	"camera_fpv_motion_blur": false,
	# FPV-9: hide the flight overlays while the onboard picture or the cockpit is shown (the OSD replaces them).
	"camera_fpv_clean_screen": true,
	"camera_fpv_quality": "high",
	"camera_fpv_head_tracking": "off",
	"camera_fpv_head_sensitivity": 1.0,
	"camera_fpv_gimbal_pan_axis": -1,
	"camera_fpv_gimbal_tilt_axis": -1,
	"camera_fpv_gimbal_pan_travel": 90,
	"camera_fpv_gimbal_tilt_travel": 45,
	"camera_fpv_gimbal_speed": "medium",
	"camera_fpv_gimbal_invert_pan": false,
	"camera_fpv_gimbal_invert_tilt": false,
	"camera_fpv_osd": FpvOsdModel.DEFAULT_STYLE,
	"camera_fpv_osd_elements": FpvOsdModel.DEFAULT_ELEMENTS,
	"camera_fpv_link": VideoLink.DEFAULT_MODE,
	"camera_fpv_vtx_power": VideoLink.DEFAULT_POWER_MW,
}


## Errors for the camera keys present in `raw` (absent keys take their defaults).
static func errors(raw: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if typeof(raw.get("camera_view", DEFAULTS.camera_view)) != TYPE_STRING or raw.get("camera_view", DEFAULTS.camera_view) not in VIEWS:
		out.append("camera_view must be pilot, chase, onboard, cockpit, flyby or orbit")
	for pair: Array in [["camera_fpv_fov", FPV_FOVS], ["camera_fpv_tilt", FPV_TILTS]]:
		var lens: Variant = raw.get(pair[0], DEFAULTS[pair[0]])
		if typeof(lens) != TYPE_INT or lens not in (pair[1] as Array):
			out.append("%s must be one of the offered values" % pair[0])
	var smoothing: Variant = raw.get("camera_fpv_smoothing", DEFAULTS.camera_fpv_smoothing)
	if typeof(smoothing) != TYPE_STRING or smoothing not in FPV_SMOOTHING:
		out.append("camera_fpv_smoothing must be off, light or medium")
	var lens: Variant = raw.get("camera_fpv_lens", DEFAULTS.camera_fpv_lens)
	if typeof(lens) != TYPE_STRING or lens not in FPV_LENSES:
		out.append("camera_fpv_lens must be rectilinear, barrel or fisheye")
	for pair: Array in [["camera_fpv_shake", FPV_SHAKES], ["camera_fpv_noise", FPV_NOISES], ["camera_fpv_quality", FPV_QUALITIES]]:
		var choice: Variant = raw.get(pair[0], DEFAULTS[pair[0]])
		if typeof(choice) != TYPE_STRING or choice not in (pair[1] as Array):
			out.append("%s must be one of %s" % [pair[0], ", ".join(pair[1])])
	if typeof(raw.get("camera_fpv_motion_blur", DEFAULTS.camera_fpv_motion_blur)) != TYPE_BOOL:
		out.append("camera_fpv_motion_blur must be a boolean")
	if typeof(raw.get("camera_fpv_clean_screen", DEFAULTS.camera_fpv_clean_screen)) != TYPE_BOOL:
		out.append("camera_fpv_clean_screen must be a boolean")
	if not FpvOsdModel.valid_elements(raw.get("camera_fpv_osd_elements", DEFAULTS.camera_fpv_osd_elements)):
		out.append("camera_fpv_osd_elements must list OSD elements (%s)" % ", ".join(FPV_OSD_ELEMENTS))
	for pair: Array in [["camera_fpv_head_tracking", FPV_HEAD_TRACKING], ["camera_fpv_gimbal_speed", FPV_GIMBAL_SPEEDS],
			["camera_fpv_osd", FPV_OSD_STYLES], ["camera_fpv_link", FPV_LINKS]]:
		var choice: Variant = raw.get(pair[0], DEFAULTS[pair[0]])
		if typeof(choice) != TYPE_STRING or choice not in (pair[1] as Array):
			out.append("%s must be one of %s" % [pair[0], ", ".join(pair[1])])
	for pair: Array in [["camera_fpv_gimbal_pan_axis", FPV_GIMBAL_AXES], ["camera_fpv_gimbal_tilt_axis", FPV_GIMBAL_AXES],
			["camera_fpv_gimbal_pan_travel", FPV_GIMBAL_PAN_TRAVELS], ["camera_fpv_gimbal_tilt_travel", FPV_GIMBAL_TILT_TRAVELS],
			["camera_fpv_vtx_power", FPV_VTX_POWERS]]:
		var number: Variant = raw.get(pair[0], DEFAULTS[pair[0]])
		if typeof(number) != TYPE_INT or number not in (pair[1] as Array):
			out.append("%s must be one of the offered values" % pair[0])
	for key: String in ["camera_fpv_gimbal_invert_pan", "camera_fpv_gimbal_invert_tilt"]:
		if typeof(raw.get(key, DEFAULTS[key])) != TYPE_BOOL:
			out.append("%s must be a boolean" % key)
	if typeof(raw.get("camera_fov", DEFAULTS.camera_fov)) != TYPE_INT or raw.get("camera_fov", DEFAULTS.camera_fov) not in FOVS:
		out.append("camera_fov must be one of the offered fields of view")
	if typeof(raw.get("camera_magnifier", DEFAULTS.camera_magnifier)) != TYPE_STRING or raw.get("camera_magnifier", DEFAULTS.camera_magnifier) not in MAGNIFIER_MODES:
		out.append("camera_magnifier must be off, auto or on")
	if typeof(raw.get("camera_zoom_law", DEFAULTS.camera_zoom_law)) != TYPE_STRING or raw.get("camera_zoom_law", DEFAULTS.camera_zoom_law) not in PilotCamera.ZOOM_LAWS:
		out.append("camera_zoom_law must be constant, partial or gentle")
	for key: String in ["camera_auto_zoom", "camera_invert_y", "camera_horizon_bias", "camera_overhead_smoothing"]:
		if typeof(raw.get(key, DEFAULTS[key])) != TYPE_BOOL:
			out.append("%s must be a boolean" % key)
	for pair: Array in [["camera_chase_distance", CHASE_DISTANCES], ["camera_sensitivity", SENSITIVITIES],
			["camera_fpv_head_sensitivity", FPV_HEAD_SENSITIVITIES]]:
		var value: Variant = raw.get(pair[0], DEFAULTS[pair[0]])
		if typeof(value) not in [TYPE_FLOAT, TYPE_INT] or not (pair[1] as Array).any(func(v: float) -> bool: return is_equal_approx(v, float(value))):
			out.append("%s must be one of the offered values" % pair[0])
	return out


## The camera keys of `raw`, normalized; call after errors() is empty.
static func normalized(raw: Dictionary) -> Dictionary:
	return {
		"camera_view": str(raw.get("camera_view", DEFAULTS.camera_view)),
		"camera_fov": int(raw.get("camera_fov", DEFAULTS.camera_fov)),
		"camera_auto_zoom": bool(raw.get("camera_auto_zoom", DEFAULTS.camera_auto_zoom)),
		"camera_zoom_law": str(raw.get("camera_zoom_law", DEFAULTS.camera_zoom_law)),
		"camera_horizon_bias": bool(raw.get("camera_horizon_bias", DEFAULTS.camera_horizon_bias)),
		"camera_overhead_smoothing": bool(raw.get("camera_overhead_smoothing", DEFAULTS.camera_overhead_smoothing)),
		"camera_magnifier": str(raw.get("camera_magnifier", DEFAULTS.camera_magnifier)),
		"camera_chase_distance": float(raw.get("camera_chase_distance", DEFAULTS.camera_chase_distance)),
		"camera_sensitivity": float(raw.get("camera_sensitivity", DEFAULTS.camera_sensitivity)),
		"camera_invert_y": bool(raw.get("camera_invert_y", DEFAULTS.camera_invert_y)),
		"camera_fpv_fov": int(raw.get("camera_fpv_fov", DEFAULTS.camera_fpv_fov)),
		"camera_fpv_tilt": int(raw.get("camera_fpv_tilt", DEFAULTS.camera_fpv_tilt)),
		"camera_fpv_smoothing": str(raw.get("camera_fpv_smoothing", DEFAULTS.camera_fpv_smoothing)),
		"camera_fpv_lens": str(raw.get("camera_fpv_lens", DEFAULTS.camera_fpv_lens)),
		"camera_fpv_shake": str(raw.get("camera_fpv_shake", DEFAULTS.camera_fpv_shake)),
		"camera_fpv_noise": str(raw.get("camera_fpv_noise", DEFAULTS.camera_fpv_noise)),
		"camera_fpv_motion_blur": bool(raw.get("camera_fpv_motion_blur", DEFAULTS.camera_fpv_motion_blur)),
		"camera_fpv_clean_screen": bool(raw.get("camera_fpv_clean_screen", DEFAULTS.camera_fpv_clean_screen)),
		"camera_fpv_quality": str(raw.get("camera_fpv_quality", DEFAULTS.camera_fpv_quality)),
		"camera_fpv_head_tracking": str(raw.get("camera_fpv_head_tracking", DEFAULTS.camera_fpv_head_tracking)),
		"camera_fpv_head_sensitivity": float(raw.get("camera_fpv_head_sensitivity", DEFAULTS.camera_fpv_head_sensitivity)),
		"camera_fpv_gimbal_pan_axis": int(raw.get("camera_fpv_gimbal_pan_axis", DEFAULTS.camera_fpv_gimbal_pan_axis)),
		"camera_fpv_gimbal_tilt_axis": int(raw.get("camera_fpv_gimbal_tilt_axis", DEFAULTS.camera_fpv_gimbal_tilt_axis)),
		"camera_fpv_gimbal_pan_travel": int(raw.get("camera_fpv_gimbal_pan_travel", DEFAULTS.camera_fpv_gimbal_pan_travel)),
		"camera_fpv_gimbal_tilt_travel": int(raw.get("camera_fpv_gimbal_tilt_travel", DEFAULTS.camera_fpv_gimbal_tilt_travel)),
		"camera_fpv_gimbal_speed": str(raw.get("camera_fpv_gimbal_speed", DEFAULTS.camera_fpv_gimbal_speed)),
		"camera_fpv_gimbal_invert_pan": bool(raw.get("camera_fpv_gimbal_invert_pan", DEFAULTS.camera_fpv_gimbal_invert_pan)),
		"camera_fpv_gimbal_invert_tilt": bool(raw.get("camera_fpv_gimbal_invert_tilt", DEFAULTS.camera_fpv_gimbal_invert_tilt)),
		"camera_fpv_osd": str(raw.get("camera_fpv_osd", DEFAULTS.camera_fpv_osd)),
		"camera_fpv_osd_elements": _osd_elements(raw.get("camera_fpv_osd_elements", DEFAULTS.camera_fpv_osd_elements)),
		"camera_fpv_link": str(raw.get("camera_fpv_link", DEFAULTS.camera_fpv_link)),
		"camera_fpv_vtx_power": int(raw.get("camera_fpv_vtx_power", DEFAULTS.camera_fpv_vtx_power)),
	}


## The OSD elements as a plain Array of ids in the model's order (the file may hold a PackedStringArray).
static func _osd_elements(value: Variant) -> Array:
	var out: Array = []
	for id: String in FPV_OSD_ELEMENTS:
		if id in value:
			out.append(id)
	return out


## A flight's start: every preference, including the first view and the chase boom.
static func apply_at_start(rig: RefCounted, preferences: Dictionary) -> void:
	var config := normalized(preferences)
	rig.onboard.set_preferences(float(config.camera_fpv_fov), float(config.camera_fpv_tilt), config.camera_fpv_smoothing)
	rig.set_view(config.camera_view)
	rig.auto_zoom = config.camera_auto_zoom
	rig.chase.zoom = config.camera_chase_distance
	apply_live(rig, config)


## A change made in Settings during a flight: the field of view and the orbit controls apply at once; the first view,
## auto-zoom and chase distance only when they changed, so a key the pilot pressed in flight is not undone.
static func apply_changes(rig: RefCounted, before: Dictionary, after: Dictionary) -> void:
	var old := normalized(before)
	var config := normalized(after)
	if config.camera_auto_zoom != old.camera_auto_zoom and rig.auto_zoom != config.camera_auto_zoom:
		rig.toggle_auto_zoom()
	if not is_equal_approx(config.camera_chase_distance, old.camera_chase_distance):
		rig.chase.zoom = config.camera_chase_distance
	# FPV-2: a changed lens setting applies at once; an unchanged one leaves the pilot's in-flight steps alone.
	if config.camera_fpv_fov != old.camera_fpv_fov or config.camera_fpv_tilt != old.camera_fpv_tilt:
		rig.onboard.set_preferences(float(config.camera_fpv_fov), float(config.camera_fpv_tilt), config.camera_fpv_smoothing)
	apply_live(rig, config)


static func apply_live(rig: RefCounted, config: Dictionary) -> void:
	rig.set_base_fov(float(config.camera_fov))
	rig.set_zoom_law(str(config.camera_zoom_law))
	rig.horizon_bias = bool(config.camera_horizon_bias)
	rig.overhead_smoothing = bool(config.camera_overhead_smoothing)
	rig.magnifier = str(config.camera_magnifier)
	rig.orbit.sensitivity = float(config.camera_sensitivity)
	rig.orbit.invert_y = bool(config.camera_invert_y)
	rig.onboard.set_smoothing(str(config.camera_fpv_smoothing))
	rig.onboard_lens = str(config.camera_fpv_lens)
	rig.onboard.set_shake(str(config.camera_fpv_shake))
	rig.onboard_video = {quality = str(config.camera_fpv_quality), noise = str(config.camera_fpv_noise),
		motion_blur = bool(config.camera_fpv_motion_blur)}
	rig.fpv_head.configure(config)
	rig.onboard_clean_screen = bool(config.camera_fpv_clean_screen)
	rig.onboard_link = {mode = str(config.camera_fpv_link), power_mw = int(config.camera_fpv_vtx_power)}
	rig.onboard_osd = {style = str(config.camera_fpv_osd), elements = (config.camera_fpv_osd_elements as Array).duplicate()}
