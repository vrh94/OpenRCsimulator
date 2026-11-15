# FPV-4: onboard camera vibration and video effects (render/camera/onboard_view.gd vibration_deg(), fpv_lens.gd).
#   - vibration: none when off, idle and still; deterministic in the clock (so independent of frame rate); grows with
#     throttle and with airspeed squared, capped; a soft mount passes less motor buzz; the lens stays on the mount;
#   - lens pass: a flat lens needs no pass unless noise or blur ask for one; the flat model maps the picture 1:1;
#     video quality caps the source pixels (low renders below the picture size);
#   - motion blur: identity for a still camera and for a cut; half of the frame's turn (the shutter) otherwise;
#   - settings: defaults are off/high; invalid values are refused; Home settings reach the rig.
# Run: godot --headless --path . --script res://tests/test_fpv_effects.gd
extends SceneTree

const OnboardView := preload("res://render/camera/onboard_view.gd")
const FpvLens := preload("res://render/camera/fpv_lens.gd")
const CameraRig := preload("res://render/camera/camera_rig.gd")
const CameraSettings := preload("res://render/camera/camera_settings.gd")
const PilotCamera := preload("res://render/pilot_camera.gd")

var _failures := 0
var _count := 0


func _check(label: String, ok: bool, detail := "") -> void:
	_count += 1
	if ok:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL %s %s" % [label, detail])


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_vibration()
	_lens_pass()
	_blur()
	_settings()
	print("all %d FPV effects checks passed" % _count if _failures == 0 else "%d of %d failed" % [_failures, _count])
	quit(1 if _failures > 0 else 0)


## Largest jitter (deg, any axis) over 20 s sampled at 50 Hz.
static func _peak(throttle: float, airspeed: float, shake: String, mount := "off") -> float:
	var peak := 0.0
	for i in 1000:
		var v := OnboardView.vibration_deg(i * 0.02, throttle, airspeed, shake, mount)
		peak = maxf(peak, maxf(absf(v.x), maxf(absf(v.y), absf(v.z))))
	return peak


func _vibration() -> void:
	_check("vibration: none when off", _peak(1.0, 40.0, "off") == 0.0)
	_check("vibration: none idle and still", _peak(0.0, 0.0, "high") == 0.0)
	var a := OnboardView.vibration_deg(12.345, 0.7, 25.0, "medium", "off")
	var b := OnboardView.vibration_deg(12.345, 0.7, 25.0, "medium", "off")
	_check("vibration: deterministic in the clock (frame-rate independent)", a == b and a != Vector3.ZERO)
	var motor_half := _peak(0.5, 0.0, "medium")
	var motor_full := _peak(1.0, 0.0, "medium")
	_check("vibration: motor buzz scales with throttle", absf(motor_full - 2.0 * motor_half) < 1e-9 and motor_full > 0.0, "%.4f vs %.4f" % [motor_full, motor_half])
	_check("vibration: motor buzz within its amplitude", motor_full <= OnboardView.MOTOR_DEG.x + 1e-9, "%.4f°" % motor_full)
	var air_15 := _peak(0.0, 15.0, "medium")
	var air_30 := _peak(0.0, 30.0, "medium")
	_check("vibration: buffeting grows with airspeed squared", absf(air_30 - 4.0 * air_15) < 1e-9, "%.4f vs %.4f" % [air_30, air_15])
	_check("vibration: buffeting is capped", is_equal_approx(_peak(0.0, 300.0, "medium"), _peak(0.0, 60.0, "medium")))
	_check("vibration: high doubles medium", is_equal_approx(_peak(1.0, 30.0, "high"), 2.0 * _peak(1.0, 30.0, "medium")))
	_check("vibration: a soft mount passes less motor buzz", _peak(1.0, 0.0, "medium", "medium") < 0.5 * motor_full)
	_check("vibration: smooth (value noise in [−1, 1], continuous)", absf(OnboardView.value_noise(3.999999, 5) - OnboardView.value_noise(4.0, 5)) < 1e-4
		and absf(OnboardView.value_noise(7.3, 2)) <= 1.0)
	var view := OnboardView.new()
	view.configure(Vector3(0, 0.1, -0.8), "estimated")
	view.set_preferences(110.0, 0.0, "off")
	view.set_shake("high")
	view.set_vibration_inputs(4.2, 1.0, 35.0)
	var at := Vector3(5, 30, -2)
	var shaken := view.update(Transform3D(Basis.IDENTITY, at), Basis.IDENTITY, 16.0 / 9.0, 1.0 / 60.0, false)
	_check("vibration: the lens stays on the mount", (shaken.position as Vector3).is_equal_approx(at + Vector3(0, 0.1, -0.8)))
	var turned := rad_to_deg(Quaternion((shaken.basis as Basis)).get_angle())
	_check("vibration: the picture turns by a small angle", turned > 0.0 and turned < 3.0, "%.4f°" % turned)


func _lens_pass() -> void:
	var lens := FpvLens.new()
	lens.set_model("rectilinear")
	_check("pass: a flat lens without effects needs none", not lens.needs_pass())
	lens.set_video("high", "low", false)
	_check("pass: noise needs it", lens.needs_pass())
	lens.set_video("high", "off", true)
	_check("pass: motion blur needs it", lens.needs_pass())
	lens.set_video("high", "bogus", false)
	_check("pass: an unknown noise value is ignored", lens.noise == "off")
	lens.free()
	var aspect := 16.0 / 9.0
	var flat := FpvLens.geometry("rectilinear", 110.0, aspect)
	var edge := FpvLens.source_point("rectilinear", Vector2(aspect, 0.0), flat)
	# The picture point is a float32 Vector2, so the bound is float32 rounding.
	_check("flat: the edge is half the FOV", absf(rad_to_deg(edge.theta) - 55.0) < 1e-5, "%.12f°" % rad_to_deg(edge.theta))
	_check("flat: the source is the picture itself", (flat.tan_extent as Vector2).is_equal_approx(Vector2(tan(deg_to_rad(55.0)), tan(deg_to_rad(55.0)) / aspect))
		and (FpvLens.source_point("rectilinear", Vector2(0.4, -0.3), flat).s as Vector2).is_equal_approx(Vector2(0.4, -0.3) / float(flat.focal)))
	var scale: Vector2 = flat.source_scale
	_check("flat: no supersampling needed at high quality", scale.is_equal_approx(Vector2.ONE), str(scale))
	var low: Vector2 = FpvLens.geometry("barrel", 110.0, aspect, FpvLens.QUALITY.low).source_scale
	_check("quality: low renders below the picture size", low.x * low.y <= 0.5625 + 1e-6 and low.y < 1.0, str(low))
	var medium: Vector2 = FpvLens.geometry("barrel", 110.0, aspect, FpvLens.QUALITY.medium).source_scale
	var high: Vector2 = FpvLens.geometry("barrel", 110.0, aspect, FpvLens.QUALITY.high).source_scale
	_check("quality: medium between low and high", low.x * low.y < medium.x * medium.y and medium.x * medium.y < high.x * high.y)


func _blur() -> void:
	var still := Basis(Vector3.UP, 0.7)
	_check("blur: a still camera does not smear", FpvLens.blur_rotation(still, still).is_equal_approx(Basis.IDENTITY))
	var before := Basis.IDENTITY
	var now := Basis(Vector3.UP, deg_to_rad(10.0)) # yawed 10° left in one frame
	var r := FpvLens.blur_rotation(now, before)
	_check("blur: half the frame's turn (the shutter)", absf(rad_to_deg(Quaternion(r).get_angle()) - 10.0 * FpvLens.SHUTTER) < 1e-3, "%.4f°" % rad_to_deg(Quaternion(r).get_angle()))
	# A ray straight ahead now pointed 5° to the right of the old view axis half a frame ago... in camera space it was
	# at the camera's right (positive x) back then.
	var ahead_then := r * Vector3(0, 0, -1)
	_check("blur: the smear follows the turn's direction", ahead_then.x < 0.0, str(ahead_then))
	_check("blur: a cut does not smear", FpvLens.blur_rotation(Basis(Vector3.UP, deg_to_rad(90.0)), before).is_equal_approx(Basis.IDENTITY))


func _settings() -> void:
	var normal := CameraSettings.normalized({})
	_check("settings: defaults off, off, no blur, high quality", normal.camera_fpv_shake == "off" and normal.camera_fpv_noise == "off"
		and normal.camera_fpv_motion_blur == false and normal.camera_fpv_quality == "high")
	_check("settings: defaults validate", CameraSettings.errors({}).is_empty())
	for bad: Dictionary in [{camera_fpv_shake = "extreme"}, {camera_fpv_noise = 1}, {camera_fpv_quality = "ultra"}, {camera_fpv_motion_blur = "yes"}]:
		_check("settings: refuses %s" % str(bad), not CameraSettings.errors(bad).is_empty())
	var cam := PilotCamera.create(get_root(), { north = 0.0, east = 0.0, down = 0.0, eye_height = 1.7 })
	var rig := CameraRig.new(cam, 1.5)
	CameraSettings.apply_at_start(rig, {camera_fpv_shake = "low", camera_fpv_noise = "medium", camera_fpv_motion_blur = true, camera_fpv_quality = "low"})
	_check("settings: reach the rig", rig.onboard.shake == "low" and rig.onboard_video.noise == "medium" and rig.onboard_video.motion_blur
		and rig.onboard_video.quality == "low")
	cam.free()
