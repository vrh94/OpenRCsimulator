# CAM-12 / FPV-3: the onboard wide-angle lens (render/camera/fpv_lens.gd; fpv_lens.gdshader mirrors source_point()).
#   - the lens model: the picture edge is exactly the chosen horizontal FOV; a ray at θ lands at the model's radius
#     (stereographic for "barrel", equidistant for "fisheye") within 1 % for every sampled angle and direction;
#   - coverage: edges and (where the image circle allows) corners sample inside the rectilinear source, beyond-89° rays
#     fall into the rim; the source never exceeds 120° vertical; supersampling stays within 1.0–1.5×;
#   - the node: inactive for the flat lens or outside the onboard picture; active it renders the flight camera's pose
#     into a supersampled viewport, skips the main 3D pass and restores it when it turns off.
# Run: godot --headless --path . --script res://tests/test_fpv_lens.gd
extends SceneTree

const FpvLens := preload("res://render/camera/fpv_lens.gd")
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
	_model()
	_coverage()
	_node()
	print("all %d FPV lens checks passed" % _count if _failures == 0 else "%d of %d failed" % [_failures, _count])
	quit(1 if _failures > 0 else 0)


func _model() -> void:
	var aspect := 16.0 / 9.0
	for lens: String in ["barrel", "fisheye"]:
		for hfov: float in [90.0, 110.0, 130.0, 150.0]:
			var geo := FpvLens.geometry(lens, hfov, aspect)
			var edge := FpvLens.source_point(lens, Vector2(aspect, 0.0), geo)
			_check("%s %d°: the picture edge is half the FOV" % [lens, hfov], absf(rad_to_deg(edge.theta) - hfov * 0.5) < 1e-6, "%.6f°" % rad_to_deg(edge.theta))
			var worst := 0.0
			for deg in range(1, int(hfov * 0.5) + 1, 4):
				var theta := deg_to_rad(float(deg))
				var expected := FpvLens.radius_at(lens, theta, float(geo.focal))
				for angle in [0.0, 0.7, 1.9, 3.3, 5.1]:
					var p := Vector2(cos(angle), sin(angle)) * expected
					var got: Dictionary = FpvLens.source_point(lens, p, geo)
					# The sampled ray's angle from the axis, from its rectilinear source point.
					var ray := atan((got.s as Vector2).length())
					worst = maxf(worst, absf(FpvLens.radius_at(lens, ray, float(geo.focal)) - expected) / expected)
			_check("%s %d°: every ray lands at the model radius (≤ 1 %%)" % [lens, hfov], worst <= 0.01, "worst %.5f %%" % (worst * 100.0))
	var barrel := FpvLens.geometry("barrel", 110.0, aspect)
	var fisheye := FpvLens.geometry("fisheye", 110.0, aspect)
	var rect_mid := tan(deg_to_rad(27.5)) / tan(deg_to_rad(55.0)) * aspect # where 27.5° sits on a flat 110° lens
	var barrel_mid := FpvLens.radius_at("barrel", deg_to_rad(27.5), float(barrel.focal))
	var fish_mid := FpvLens.radius_at("fisheye", deg_to_rad(27.5), float(fisheye.focal))
	_check("barrel magnifies the centre over a flat lens of the same FOV", barrel_mid > rect_mid, "%.3f vs %.3f" % [barrel_mid, rect_mid])
	_check("fisheye magnifies it more than barrel", fish_mid > barrel_mid, "%.3f vs %.3f" % [fish_mid, barrel_mid])


func _coverage() -> void:
	var aspect := 16.0 / 9.0
	for lens: String in ["barrel", "fisheye"]:
		for hfov: float in [70.0, 110.0, 150.0]:
			var geo := FpvLens.geometry(lens, hfov, aspect)
			_check("%s %d°: source within 120° vertical" % [lens, hfov], float(geo.source_vfov_deg) <= 120.0 + 1e-9, "%.2f°" % geo.source_vfov_deg)
			var scale: Vector2 = geo.source_scale
			_check("%s %d°: source pixels within 1–2.25× the picture" % [lens, hfov], scale.x * scale.y >= 1.0 - 1e-9 and scale.x * scale.y <= 2.25 + 1e-9, str(scale))
			_check("%s %d°: source aspect matches its tan extent" % [lens, hfov], absf(scale.x / scale.y * aspect - (geo.tan_extent as Vector2).x / (geo.tan_extent as Vector2).y) < 1e-5) # Vector2 is float32
			var inside := true
			for p: Vector2 in [Vector2(aspect * 0.999, 0), Vector2(0, 0.999), Vector2(-aspect * 0.999, 0), Vector2(0, -0.999)]:
				inside = inside and FpvLens.source_point(lens, p, geo).inside
			_check("%s %d°: edge midpoints sample inside the source" % [lens, hfov], inside)
	var mild := FpvLens.geometry("barrel", 110.0, aspect)
	_check("barrel 110°: corners still inside the image circle", FpvLens.source_point("barrel", Vector2(aspect, 1.0) * 0.999, mild).inside)
	var wide := FpvLens.geometry("fisheye", 150.0, aspect)
	_check("fisheye 150°: corners fall into the dark rim", not FpvLens.source_point("fisheye", Vector2(aspect, 1.0) * 0.999, wide).inside)
	var flat := FpvLens.source_point("barrel", Vector2.ZERO, mild)
	_check("the centre samples the source centre", flat.inside and (flat.s as Vector2).is_zero_approx())
	var capped: Vector2 = FpvLens.geometry("fisheye", 150.0, aspect, 1.2).source_scale
	_check("a capped pixel budget is honoured", capped.x * capped.y <= 1.44 + 1e-9, str(capped))


func _node() -> void:
	var main := get_root()
	var camera := PilotCamera.create(main, { north = 0.0, east = 0.0, down = 0.0, eye_height = 1.7 })
	camera.global_transform = Transform3D(Basis(Vector3.UP, 0.5), Vector3(3, 20, -7))
	camera.near = 0.03
	var lens := FpvLens.new()
	lens.build(main)
	var was_disabled := main.disable_3d
	lens.update(camera, false, 110.0)
	_check("node: off outside the onboard picture", not lens.active and main.disable_3d == was_disabled)
	lens.set_model("rectilinear")
	lens.update(camera, true, 110.0)
	_check("node: the flat lens needs no warp", not lens.active and main.disable_3d == was_disabled)
	lens.set_model("barrel")
	lens.update(camera, true, 110.0)
	var evidence := lens.evidence()
	var size := Vector2(main.get_visible_rect().size)
	var geo := FpvLens.geometry("barrel", 110.0, size.x / size.y)
	var lens_camera := lens.find_child("FpvLensCamera", true, false) as Camera3D
	_check("node: active in the onboard picture", lens.active and evidence.active)
	_check("node: the main 3D pass is skipped while active", main.disable_3d)
	var scale: Vector2 = geo.source_scale
	_check("node: supersampled source size", evidence.viewport_size == Vector2i(roundi(size.x * scale.x), roundi(size.y * scale.y)), "%s for %s" % [evidence.viewport_size, size])
	_check("node: renders the flight camera's pose", lens_camera.global_transform.is_equal_approx(camera.global_transform) and lens_camera.near == camera.near)
	_check("node: with the source FOV", is_equal_approx(lens_camera.fov, float(geo.source_vfov_deg)))
	_check("node: the lens layer is below every overlay", (lens.find_child("FpvLensLayer", true, false) as CanvasLayer).layer < 0)
	_check("node: its viewport never becomes an audio listener", not (lens.find_child("FpvLensViewport", true, false) as SubViewport).audio_listener_enable_3d)
	lens.update(camera, false, 110.0)
	_check("node: leaving restores the main 3D pass", not lens.active and main.disable_3d == was_disabled)
	lens.update(camera, true, 110.0)
	lens.queue_free()
	await process_frame
	_check("node: freeing an active lens restores the main 3D pass", main.disable_3d == was_disabled)
	camera.free()
