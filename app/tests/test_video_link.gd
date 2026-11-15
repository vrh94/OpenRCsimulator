# FPV-7: the analog video link (render/camera/video_link.gd) and its picture breakup (fpv_lens.gd).
#   - margin: half broken at R_half, −6 dB per doubled distance, R_half grows with √power, terrain and scenery block;
#   - quality: clean close in, lost far out or behind a hill; fades fast and recovers slower; off is always clean;
#   - outputs: breakup for the shader, the OSD's signal figure (none when off);
#   - lens: breakup needs the pass even with a flat lens; settings defaults, refusals, the rig receives them.
# Run: godot --headless --path . --script res://tests/test_video_link.gd
extends SceneTree

const VideoLink := preload("res://render/camera/video_link.gd")
const FpvLens := preload("res://render/camera/fpv_lens.gd")
const FpvOsdModel := preload("res://render/overlays/fpv_osd_model.gd")
const CameraSettings := preload("res://render/camera/camera_settings.gd")
const CameraRig := preload("res://render/camera/camera_rig.gd")
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
	_margin()
	_quality()
	_outputs()
	_lens_and_settings()
	print("all %d video link checks passed" % _count if _failures == 0 else "%d of %d failed" % [_failures, _count])
	quit(1 if _failures > 0 else 0)


func _margin() -> void:
	var r := VideoLink.half_range_m(600.0)
	_check("margin: R_half scales with √power", is_equal_approx(r, VideoLink.R_HALF_25MW_M * 2.0 * sqrt(6.0)) and is_equal_approx(VideoLink.half_range_m(25.0), 600.0))
	_check("margin: zero at R_half", absf(VideoLink.margin_db(r, 600.0, false, 0.0, NAN)) < 1e-9)
	_check("margin: −6 dB per doubled distance", absf(VideoLink.margin_db(2.0 * r, 600.0, false, 0.0, NAN) + 6.0206) < 1e-3)
	_check("margin: terrain blocks", is_equal_approx(VideoLink.margin_db(r, 600.0, true, 0.0, NAN), -VideoLink.OBSTRUCTION_DB))
	_check("margin: scenery blocks in proportion", is_equal_approx(VideoLink.margin_db(r, 600.0, false, 0.5, NAN), -0.5 * VideoLink.SCENERY_DB))
	var flutter := 0.0
	for i in 200:
		flutter = maxf(flutter, absf(VideoLink.margin_db(r, 600.0, false, 0.0, i * 0.013)))
	_check("margin: flutter is small", flutter > 0.0 and flutter <= VideoLink.FLUTTER_DB + 1e-9, "%.3f dB" % flutter)
	_check("margin: deterministic in the clock", VideoLink.margin_db(800.0, 200.0, false, 0.2, 3.21) == VideoLink.margin_db(800.0, 200.0, false, 0.2, 3.21))


func _quality() -> void:
	_check("quality: half at zero margin", is_equal_approx(VideoLink.quality_of(0.0), 0.5))
	_check("quality: clean and lost at the span", VideoLink.quality_of(6.0) == 1.0 and VideoLink.quality_of(-6.0) == 0.0)
	var link := VideoLink.new()
	link.configure("analog", 600)
	_check("quality: clean near the field", link.update(80.0, false, 0.0, 1.0, 1.0 / 60.0) == 1.0)
	link.reset()
	_check("quality: lost far away", link.update(20000.0, false, 0.0, 1.0, 1.0 / 60.0) == 0.0)
	link.reset()
	link.update(300.0, false, 0.0, 1.0, 1.0 / 60.0)
	_check("quality: a hill in the way loses the picture at 300 m (25 mW)", (func() -> bool:
		var weak := VideoLink.new()
		weak.configure("analog", 25)
		return weak.update(300.0, true, 0.0, NAN, 0.0) < 0.05).call())
	# Fade fast, recover slower: from clean into a blocked path and back, 0.1 s each.
	var fading := VideoLink.new()
	fading.configure("analog", 25)
	fading.update(100.0, false, 0.0, NAN, 0.0)
	for i in 6:
		fading.update(1500.0, false, 0.0, NAN, 1.0 / 60.0)
	var faded := 1.0 - fading.quality
	for i in 30:
		fading.update(1500.0, false, 0.0, NAN, 1.0 / 60.0)
	for i in 6:
		fading.update(100.0, false, 0.0, NAN, 1.0 / 60.0)
	_check("quality: fades faster than it recovers", faded > 0.7 and fading.quality < 0.5, "faded %.3f recovered to %.3f" % [faded, fading.quality])
	var off := VideoLink.new()
	off.configure("off", 25)
	_check("quality: off is always clean", off.update(50000.0, true, 1.0, 1.0, 1.0 / 60.0) == 1.0 and off.breakup() == 0.0)


func _outputs() -> void:
	var link := VideoLink.new()
	link.configure("analog", 200)
	link.update(VideoLink.half_range_m(200.0), false, 0.0, NAN, 0.0)
	_check("outputs: breakup is the lost share", is_equal_approx(link.breakup(), 0.5))
	_check("outputs: the OSD signal figure", is_equal_approx(float(link.osd_link().quality_pct), 50.0))
	var off := VideoLink.new()
	off.configure("off", 200)
	_check("outputs: no figure when off", off.osd_link().is_empty())
	var values := FpvOsdModel.values({}, {}, link.osd_link())
	_check("outputs: the OSD shows it as signal strength", FpvOsdModel.items("ardupilot", values, ["link"], "metric")[0].text == "RSSI 50")


func _lens_and_settings() -> void:
	var lens := FpvLens.new()
	lens.set_model("rectilinear")
	_check("lens: a clean flat picture needs no pass", not lens.needs_pass())
	lens.breakup = 0.3
	_check("lens: breakup needs the pass", lens.needs_pass())
	lens.free()
	_check("settings: defaults validate", CameraSettings.errors({}).is_empty())
	var normal := CameraSettings.normalized({})
	_check("settings: analog link at 600 mW by default", normal.camera_fpv_link == "analog" and normal.camera_fpv_vtx_power == 600)
	for bad: Dictionary in [{camera_fpv_link = "digital"}, {camera_fpv_vtx_power = 800}, {camera_fpv_vtx_power = "600"}]:
		_check("settings: refuses %s" % str(bad), not CameraSettings.errors(bad).is_empty())
	var cam := PilotCamera.create(get_root(), { north = 0.0, east = 0.0, down = 0.0, eye_height = 1.7 })
	var rig := CameraRig.new(cam, 1.5)
	CameraSettings.apply_at_start(rig, {camera_fpv_link = "off", camera_fpv_vtx_power = 25})
	_check("settings: reach the rig", rig.onboard_link.mode == "off" and rig.onboard_link.power_mw == 25)
	cam.free()
