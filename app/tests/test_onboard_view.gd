# CAM-11 / FPV-1: the fixed-wing onboard (FPV) view (render/camera/onboard_view.gd, camera_rig.gd).
#   - the nose mount estimate: just behind the foremost geometry, on the centreline, above the fuselage top; the
#     propeller never defines the nose; an empty model has no mount;
#   - the lens is rigid: it follows position, pitch and roll exactly, tilts up about the body's right axis and scales
#     with the model root; the FOV converts horizontal to vertical;
#   - the rig: no onboard view (key 3, C cycle) without a mount; with one, the cycle visits it after chase; near plane
#     0.03 m; the picture is identical at any frame time (no smoothing);
#   - a crash aftermath orbits the wreck starting from the lens; a restart returns to the lens;
#   - FPV-2: FOV/tilt steps stay within limits and Backspace restores the settings; −/= step the lens in the rig;
#     the soft mount trails a step and settles, at the same rate at 30 and 240 fps, holds while paused, never moves
#     the lens off the mount and starts settled after a cut; settings validate, apply at start and on change.
# Run: godot --headless --path . --script res://tests/test_onboard_view.gd
extends SceneTree

const PilotCamera := preload("res://render/pilot_camera.gd")
const CameraRig := preload("res://render/camera/camera_rig.gd")
const CameraSettings := preload("res://render/camera/camera_settings.gd")
const OnboardView := preload("res://render/camera/onboard_view.gd")

const SPAN := 1.5
const EPS := 1e-5

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
	_mount_estimate()
	_mount_from_meshes()
	_rigid_lens()
	_rig_views()
	_wreck()
	_lens_steps()
	_soft_mount()
	_settings()
	print("all %d onboard view checks passed" % _count if _failures == 0 else "%d of %d failed" % [_failures, _count])
	quit(1 if _failures > 0 else 0)


static func _flat(_x: float, _z: float) -> float:
	return 0.0


## A box's surface as triangles (model frame), from Godot's own BoxMesh.
static func _box(lo: Vector3, hi: Vector3) -> PackedVector3Array:
	var mesh := BoxMesh.new()
	mesh.size = hi - lo
	var centre := 0.5 * (lo + hi)
	var out := PackedVector3Array()
	for p in mesh.get_faces():
		out.append(p + centre)
	return out


## A 1.5 m fuselage (nose at z = −1, top at y = 0.1) with a wing at the CG and a taller fin at the tail.
static func _airplane_faces() -> PackedVector3Array:
	var faces := _box(Vector3(-0.06, -0.08, -1.0), Vector3(0.06, 0.1, 0.5))
	faces.append_array(_box(Vector3(-0.75, 0.0, -0.2), Vector3(0.75, 0.03, 0.1)))
	faces.append_array(_box(Vector3(-0.01, 0.1, 0.35), Vector3(0.01, 0.35, 0.5)))
	return faces


func _mount_estimate() -> void:
	var estimate := OnboardView.estimate_from_faces(_airplane_faces())
	var length := 1.5
	_check("estimate: ok and labelled estimated", estimate.ok and estimate.source == "estimated")
	_check("estimate: just behind the nose", absf(estimate.position.z - (-1.0 + OnboardView.NOSE_SETBACK_SHARE * length)) < EPS, str(estimate.position))
	_check("estimate: on the centreline", absf(estimate.position.x) < EPS)
	_check("estimate: on the fuselage top, not the fin", absf(estimate.position.y - (0.1 + OnboardView.MOUNT_CLEARANCE_M)) < EPS, str(estimate.position))
	var empty := OnboardView.estimate_from_faces(PackedVector3Array())
	_check("estimate: no geometry, no mount", not empty.ok and not (empty.position as Vector3).is_finite())
	# A flying wing: no fuselage, the centre section is the nose (Moonrunner-like). The lens sits on its top surface.
	var wing := _box(Vector3(-1.0, -0.04, -0.3), Vector3(1.0, 0.05, 0.3))
	var flying := OnboardView.estimate_from_faces(wing)
	_check("estimate: a flying wing gets a lens on its centre section", flying.ok and absf(flying.position.y - (0.05 + OnboardView.MOUNT_CLEARANCE_M)) < EPS, str(flying.position))
	# An open frame: a gap on the centreline at the station; a nearby line finds the structure.
	var rails := _box(Vector3(0.02, 0.0, -0.5), Vector3(0.04, 0.03, 0.5))
	rails.append_array(_box(Vector3(-0.04, 0.0, -0.5), Vector3(-0.02, 0.03, 0.5)))
	var frame := OnboardView.estimate_from_faces(rails)
	_check("estimate: an open frame falls back to a nearby line", frame.ok and absf(frame.position.y - (0.03 + OnboardView.MOUNT_CLEARANCE_M)) < EPS, str(frame.position))
	_check("surface_top: a line missing every triangle meets nothing", OnboardView.surface_top(wing, 5.0, 0.0) == -INF)


func _mount_from_meshes() -> void:
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.18, 1.5) # nose at z = −0.75, top at y = 0.09
	body.mesh = box
	root.add_child(body)
	var propeller := Node3D.new()
	propeller.name = "propeller"
	var disc := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.2
	cylinder.bottom_radius = 0.2
	cylinder.height = 0.02
	disc.mesh = cylinder
	disc.position = Vector3(0, 0, -0.9)
	propeller.add_child(disc)
	root.add_child(propeller)
	get_root().add_child(root)
	root.position = Vector3(10, 20, 30) # the frame is the root's own, wherever it stands
	root.rotation = Vector3(0.3, 1.0, 0.2)
	var estimate := OnboardView.derive_mount(root)
	_check("meshes: the propeller disc never defines the nose", absf(estimate.nose_z - (-0.75)) < 1e-4, "nose %.4f" % estimate.nose_z)
	_check("meshes: mount on the fuselage top behind the nose",
		(estimate.position as Vector3).is_equal_approx(Vector3(0.0, 0.09 + OnboardView.MOUNT_CLEARANCE_M, -0.75 + OnboardView.NOSE_SETBACK_SHARE * 1.5)),
		str(estimate.position))
	root.free()


func _rigid_lens() -> void:
	var view := OnboardView.new()
	var mount := Vector3(0.0, 0.12, -0.9)
	view.configure(mount, "estimated")
	view.tilt_deg = 0.0
	var level := Basis.IDENTITY
	var at := Vector3(5, 30, -40)
	var placed := view.placement(Transform3D(level, at), level, 16.0 / 9.0)
	_check("lens: at the mount", (placed.position as Vector3).is_equal_approx(at + mount))
	_check("lens: looks along the nose with no tilt", (-(placed.basis as Basis).z).is_equal_approx(Vector3.FORWARD))
	view.tilt_deg = 10.0
	placed = view.placement(Transform3D(level, at), level, 16.0 / 9.0)
	var forward: Vector3 = -(placed.basis as Basis).z
	_check("lens: uptilt raises the view by the tilt", absf(rad_to_deg(asin(forward.y)) - 10.0) < 1e-4, "%.5f°" % rad_to_deg(asin(forward.y)))
	view.tilt_deg = 0.0
	var rolled := Basis(Vector3.FORWARD, deg_to_rad(-30.0)) # right wing down seen from behind
	placed = view.placement(Transform3D(rolled, at), rolled, 16.0 / 9.0)
	_check("lens: full roll, no stabilisation", (placed.basis as Basis).y.is_equal_approx(rolled.y) and (placed.basis as Basis).x.is_equal_approx(rolled.x))
	var scaled := Transform3D(level.scaled(Vector3.ONE * 2.0), at)
	placed = view.placement(scaled, level, 16.0 / 9.0)
	_check("lens: a scaled model carries the mount with it", (placed.position as Vector3).is_equal_approx(at + mount * 2.0))
	_check("lens: 90° horizontal at aspect 1 is 90° vertical", absf(OnboardView.vertical_fov_deg(90.0, 1.0) - 90.0) < 1e-9)
	_check("lens: 110° horizontal at 16:9", absf(OnboardView.vertical_fov_deg(110.0, 16.0 / 9.0) - rad_to_deg(2.0 * atan(tan(deg_to_rad(55.0)) * 9.0 / 16.0))) < 1e-9)


func _camera() -> Camera3D:
	return PilotCamera.create(get_root(), { north = 0.0, east = 0.0, down = 0.0, eye_height = 1.7 })


func _rig_views() -> void:
	var cam := _camera()
	var rig := CameraRig.new(cam, SPAN)
	_check("rig: no onboard view without a mount", not rig.set_view("onboard") and rig.view == "pilot")
	var seen := []
	for i in CameraRig.VIEWS.size() - 2: # FPV-8: the cockpit is unavailable too
		seen.append(rig.view)
		rig.cycle(1)
	_check("rig: C skips onboard without a mount", seen == ["pilot", "chase", "flyby", "orbit", "closeup"] and rig.view == "pilot", str(seen))
	rig.onboard.configure(Vector3(0, 0.1, -0.8), "estimated")
	rig.cycle(1)
	rig.cycle(1)
	_check("rig: with a mount, C visits onboard after chase", rig.view == "onboard")
	rig.cycle(-1)
	_check("rig: Shift+C goes back to chase", rig.view == "chase")
	_check("rig: key 3 selects onboard", rig.set_view("onboard") and rig.view_name() == "onboard FPV")
	var at := Vector3(0, 40, -100)
	var body := Basis(Vector3.UP, 0.4) * Basis(Vector3.RIGHT, 0.2) * Basis(Vector3.FORWARD, 0.5)
	var airplane := Transform3D(body, at)
	rig.update(at, airplane, body, 1.0 / 30.0, false, _flat)
	var slow := cam.transform
	var expected: Dictionary = rig.onboard.placement(airplane, body, rig._aspect())
	_check("rig: near plane 0.03 m", is_equal_approx(cam.near, PilotCamera.projection_value(0.03)), "%f" % cam.near)
	_check("rig: camera is the lens placement", cam.transform.is_equal_approx(Transform3D(expected.basis, expected.position)))
	rig.update(at, airplane, body, 1.0 / 144.0, false, _flat)
	_check("rig: same picture at 30 and 144 fps (rigid, no smoothing)", cam.transform == slow)
	_check("rig: evidence names the mount source", rig.evidence().onboard.source == "estimated")
	rig.onboard.clear()
	_check("rig: a cleared mount refuses the view again", not rig.available("onboard"))
	cam.free()


func _wreck() -> void:
	var cam := _camera()
	var rig := CameraRig.new(cam, SPAN)
	rig.onboard.configure(Vector3(0, 0.1, -0.8), "estimated")
	rig.set_view("onboard")
	var impact := Vector3(40, 0.3, -50)
	var wreck := Vector3(36, 0.4, -47)
	var airplane := Transform3D(Basis.IDENTITY, impact)
	rig.update(impact, airplane, Basis.IDENTITY, 1.0 / 60.0, true, _flat)
	var lens := cam.position
	rig.focus(wreck, _flat)
	var to_wreck := (wreck - cam.position).normalized()
	_check("wreck: the aftermath looks at the wreck", (-cam.basis.z).dot(to_wreck) > 0.999, "%f" % (-cam.basis.z).dot(to_wreck))
	_check("wreck: the orbit starts where the lens was (no jump)", cam.position.distance_to(lens) < 0.05, "%.3f m" % cam.position.distance_to(lens))
	_check("wreck: the view stays onboard for the restart", rig.view == "onboard")
	rig.reset()
	rig.update(impact, airplane, Basis.IDENTITY, 1.0 / 60.0, false, _flat)
	_check("wreck: a restart returns to the lens", cam.position.is_equal_approx(lens))
	cam.free()


func _lens_steps() -> void:
	var view := OnboardView.new()
	view.set_preferences(110.0, 5.0, "off")
	_check("steps: = narrows by 10°", view.adjust_fov(-1) and view.hfov_deg == 100.0)
	for i in 20:
		view.adjust_fov(-1)
	_check("steps: FOV stops at its minimum", view.hfov_deg == OnboardView.HFOV_MIN_DEG and not view.adjust_fov(-1))
	for i in 20:
		view.adjust_tilt(1)
	_check("steps: tilt stops at its maximum", view.tilt_deg == OnboardView.TILT_MAX_DEG and not view.adjust_tilt(1))
	_check("steps: Backspace restores the settings", view.reset_lens() and view.hfov_deg == 110.0 and view.tilt_deg == 5.0)
	_check("steps: nothing to restore reports no change", not view.reset_lens())
	view.set_preferences(500.0, -90.0, "off")
	_check("steps: preferences are clamped", view.hfov_deg == OnboardView.HFOV_MAX_DEG and view.tilt_deg == OnboardView.TILT_MIN_DEG)
	var cam := _camera()
	var rig := CameraRig.new(cam, SPAN)
	rig.onboard.configure(Vector3(0, 0.1, -0.8), "estimated")
	rig.set_view("onboard")
	rig.zoom(1.0)
	_check("rig: = (zoom in) narrows the onboard lens", rig.onboard.hfov_deg == OnboardView.DEFAULT_HFOV_DEG - OnboardView.HFOV_STEP_DEG)
	rig.zoom(-1.0)
	rig.zoom(-1.0)
	_check("rig: − widens it", rig.onboard.hfov_deg == OnboardView.DEFAULT_HFOV_DEG + OnboardView.HFOV_STEP_DEG)
	var chase_zoom: float = rig.chase.zoom
	rig.reset_view()
	_check("rig: Backspace restores the onboard lens only", rig.onboard.hfov_deg == OnboardView.DEFAULT_HFOV_DEG and rig.chase.zoom == chase_zoom)
	cam.free()


## Lens forward direction after rolling the airframe 30° at once and holding it for `seconds` at `fps`.
func _soft_step(mode: String, fps: float, seconds: float) -> Dictionary:
	var view := OnboardView.new()
	view.configure(Vector3(0, 0.1, -0.8), "estimated")
	view.set_preferences(110.0, 0.0, mode)
	var at := Vector3(0, 30, 0)
	view.update(Transform3D(Basis.IDENTITY, at), Basis.IDENTITY, 1.0, 1.0 / fps, false)
	var rolled := Basis(Vector3.FORWARD, deg_to_rad(30.0))
	var placed := {}
	for i in roundi(seconds * fps):
		placed = view.update(Transform3D(rolled, at), rolled, 1.0, 1.0 / fps, false)
	return { placed = placed, rolled = rolled, view = view }


func _soft_mount() -> void:
	var rigid := _soft_step("off", 60.0, 1.0 / 60.0)
	_check("mount: rigid follows a roll in the same frame", (rigid.placed.basis as Basis).is_equal_approx(rigid.rolled))
	var early := _soft_step("medium", 60.0, 0.05)
	var lag := rad_to_deg(Quaternion((early.placed.basis as Basis)).angle_to(Quaternion(early.rolled)))
	_check("mount: a soft mount trails a sudden roll", lag > 5.0 and lag < 30.0, "%.2f°" % lag)
	var settled := _soft_step("medium", 60.0, 2.0)
	# float32 acos near 1 resolves about 0.03°, so the settled bound is 0.1°.
	var residual := rad_to_deg(Quaternion((settled.placed.basis as Basis)).angle_to(Quaternion(settled.rolled)))
	_check("mount: and settles on the airframe", residual < 0.1, "%.4f°" % residual)
	_check("mount: the lens never leaves the mount", (early.placed.position as Vector3).is_equal_approx(Vector3(0, 30, 0) + early.rolled * Vector3(0, 0.1, -0.8)))
	var slow := _soft_step("light", 30.0, 0.1)
	var fast := _soft_step("light", 240.0, 0.1)
	var a := Quaternion((slow.placed.basis as Basis)).angle_to(Quaternion(slow.rolled))
	var b := Quaternion((fast.placed.basis as Basis)).angle_to(Quaternion(fast.rolled))
	_check("mount: the same lag at 30 and 240 fps", absf(a - b) < deg_to_rad(0.05), "%.4f° vs %.4f°" % [rad_to_deg(a), rad_to_deg(b)])
	var view: OnboardView = early.view
	var held: Basis = early.placed.basis
	var paused: Dictionary = view.update(Transform3D(early.rolled, Vector3(0, 30, 0)), early.rolled, 1.0, 1.0 / 60.0, true)
	_check("mount: holds while paused", (paused.basis as Basis).is_equal_approx(held))
	view.snap()
	var cut: Dictionary = view.update(Transform3D(early.rolled, Vector3(0, 30, 0)), early.rolled, 1.0, 1.0 / 60.0, false)
	_check("mount: starts settled after a cut", (cut.basis as Basis).is_equal_approx(early.rolled))


func _settings() -> void:
	_check("settings: defaults validate", CameraSettings.errors({}).is_empty())
	_check("settings: onboard is an offered first view", CameraSettings.errors({camera_view = "onboard"}).is_empty())
	_check("settings: an unoffered FPV FOV is refused", not CameraSettings.errors({camera_fpv_fov = 115}).is_empty())
	_check("settings: a float tilt is refused", not CameraSettings.errors({camera_fpv_tilt = 5.0}).is_empty())
	_check("settings: an unknown mount is refused", not CameraSettings.errors({camera_fpv_smoothing = "gimbal"}).is_empty())
	var normal := CameraSettings.normalized({})
	_check("settings: defaults are 110°, +5°, rigid", normal.camera_fpv_fov == 110 and normal.camera_fpv_tilt == 5 and normal.camera_fpv_smoothing == "off")
	var cam := _camera()
	var rig := CameraRig.new(cam, SPAN)
	rig.onboard.configure(Vector3(0, 0.1, -0.8), "estimated")
	var chosen := {camera_view = "onboard", camera_fpv_fov = 130, camera_fpv_tilt = 15, camera_fpv_smoothing = "light"}
	CameraSettings.apply_at_start(rig, chosen)
	_check("settings: a flight starts in the chosen onboard lens", rig.view == "onboard" and rig.onboard.hfov_deg == 130.0
		and rig.onboard.tilt_deg == 15.0 and rig.onboard.smoothing == "light")
	rig.onboard.adjust_tilt(1)
	var softer := chosen.duplicate()
	softer.camera_fpv_smoothing = "medium"
	CameraSettings.apply_changes(rig, chosen, softer)
	_check("settings: changing only the mount keeps an in-flight tilt", rig.onboard.tilt_deg == 20.0 and rig.onboard.smoothing == "medium")
	var wider := softer.duplicate()
	wider.camera_fpv_fov = 140
	CameraSettings.apply_changes(rig, softer, wider)
	_check("settings: a changed lens applies at once", rig.onboard.hfov_deg == 140.0 and rig.onboard.tilt_deg == 15.0)
	var helicopter := CameraRig.new(cam, SPAN)
	CameraSettings.apply_at_start(helicopter, chosen)
	_check("settings: no mount (helicopter) keeps the pilot view", helicopter.view == "pilot")
	cam.free()
