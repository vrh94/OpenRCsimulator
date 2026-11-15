# FPV-8: the cockpit view (Shift+3): a pilot's eye on the airframe with a canopy frame.
#   - the eye estimate: a quarter of the length aft of the nose, on the centreline, just above the fuselage top,
#     behind the FPV nose mount; an empty model has none;
#   - the rig: no cockpit view without an eye; with one, C visits it after onboard; rigid on the airframe, 90° wide,
#     no lens tilt; −/= step its field of view; head-look turns it, the radio gimbal does not; Backspace re-centres;
#     the canopy frame shows only over the eye, not over a crash orbit;
#   - the canopy frame: centred with the head forward, slides opposite a head turn and stops at its limit, covers
#     the corners and the coaming but not the middle of the picture;
#   - settings: cockpit is a first view, refused never, falls back to the pilot view without an eye.
# Run: godot --headless --path . --script res://tests/test_cockpit_view.gd
extends SceneTree

const PilotCamera := preload("res://render/pilot_camera.gd")
const CameraRig := preload("res://render/camera/camera_rig.gd")
const CameraSettings := preload("res://render/camera/camera_settings.gd")
const OnboardView := preload("res://render/camera/onboard_view.gd")
const CanopyFrame := preload("res://render/overlays/canopy_frame.gd")

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
	_eye_estimate()
	_rig_views()
	_rigid_eye()
	_head_and_gimbal()
	_wreck()
	_canopy()
	_settings()
	print("all %d cockpit view checks passed" % _count if _failures == 0 else "%d of %d failed" % [_failures, _count])
	quit(1 if _failures > 0 else 0)


static func _flat(_x: float, _z: float) -> float:
	return 0.0


static func _box(lo: Vector3, hi: Vector3) -> PackedVector3Array:
	var mesh := BoxMesh.new()
	mesh.size = hi - lo
	var centre := 0.5 * (lo + hi)
	var out := PackedVector3Array()
	for p in mesh.get_faces():
		out.append(p + centre)
	return out


## A 1.5 m fuselage (nose at z = −1, top at y = 0.1) with a wing and a fin.
static func _airplane_faces() -> PackedVector3Array:
	var faces := _box(Vector3(-0.06, -0.08, -1.0), Vector3(0.06, 0.1, 0.5))
	faces.append_array(_box(Vector3(-0.75, 0.0, -0.2), Vector3(0.75, 0.03, 0.1)))
	faces.append_array(_box(Vector3(-0.01, 0.1, 0.35), Vector3(0.01, 0.35, 0.5)))
	return faces


func _camera() -> Camera3D:
	return PilotCamera.create(get_root(), { north = 0.0, east = 0.0, down = 0.0, eye_height = 1.7 })


func _rig_with_eye() -> Array:
	var cam := _camera()
	var rig := CameraRig.new(cam, SPAN)
	rig.onboard.configure(Vector3(0, 0.12, -0.91), "estimated")
	rig.cockpit.configure(Vector3(0, 0.145, -0.625), "estimated")
	return [cam, rig]


func _eye_estimate() -> void:
	var faces := _airplane_faces()
	var eye := OnboardView.estimate_cockpit(faces)
	var mount := OnboardView.estimate_from_faces(faces)
	_check("eye: found", eye.ok)
	_check("eye: a quarter of the length aft of the nose", absf(eye.position.z - (-1.0 + 0.25 * 1.5)) < EPS, str(eye.position))
	_check("eye: on the centreline", absf(eye.position.x) < EPS)
	_check("eye: just above the fuselage top", absf(eye.position.y - (0.1 + 0.03 * 1.5)) < EPS, str(eye.position))
	_check("eye: behind the FPV nose mount", eye.position.z > mount.position.z + 0.2)
	_check("eye: none without geometry", not OnboardView.estimate_cockpit(PackedVector3Array()).ok)
	var small := OnboardView.estimate_cockpit(_box(Vector3(-0.02, -0.02, -0.3), Vector3(0.02, 0.02, 0.1)))
	_check("eye: at least 3 cm above a small model", small.ok and absf(small.position.y - (0.02 + OnboardView.EYE_MIN_M)) < EPS, str(small))
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.18, 1.5)
	mi.mesh = box
	root.add_child(mi)
	var derived := OnboardView.derive_cockpit(root)
	_check("eye: from built meshes", derived.ok and absf(derived.position.z - (-0.75 + 0.375)) < EPS, str(derived))
	root.free()


func _rig_views() -> void:
	var cam := _camera()
	var rig := CameraRig.new(cam, SPAN)
	_check("rig: no cockpit without an eye", not rig.set_view("cockpit") and rig.view == "pilot" and not rig.available("cockpit"))
	cam.free()
	var pair := _rig_with_eye()
	cam = pair[0]
	rig = pair[1]
	var seen := []
	for i in CameraRig.VIEWS.size():
		seen.append(rig.view)
		rig.cycle(1)
	_check("rig: C visits cockpit after onboard", seen == ["pilot", "chase", "onboard", "cockpit", "flyby", "orbit", "closeup"], str(seen))
	_check("rig: Shift+3 selects the cockpit", rig.set_view("cockpit") and rig.view_name() == "cockpit")
	_check("rig: cockpit lens defaults", is_equal_approx(rig.cockpit.hfov_deg, OnboardView.COCKPIT_HFOV_DEG) and rig.cockpit.tilt_deg == 0.0)
	rig.zoom(1.0)
	_check("rig: = narrows the cockpit eye", rig.cockpit.hfov_deg < OnboardView.COCKPIT_HFOV_DEG and is_equal_approx(rig.onboard.hfov_deg, OnboardView.DEFAULT_HFOV_DEG))
	rig.reset_view()
	_check("rig: Backspace restores it", is_equal_approx(rig.cockpit.hfov_deg, OnboardView.COCKPIT_HFOV_DEG))
	_check("rig: right-drag looks around", rig.drag_holds_cursor())
	_check("rig: the eye shows the canopy, the FPV lens is off", rig.showing_cockpit() and not rig.showing_onboard_lens())
	cam.free()


func _rigid_eye() -> void:
	var pair := _rig_with_eye()
	var cam: Camera3D = pair[0]
	var rig: RefCounted = pair[1]
	rig.set_view("cockpit")
	var at := Vector3(10, 40, -100)
	var body := Basis(Vector3.UP, 0.4) * Basis(Vector3.RIGHT, 0.2) * Basis(Vector3.FORWARD, 0.5)
	rig.update(at, Transform3D(body, at), body, 1.0 / 30.0, false, _flat)
	var expected := at + body * Vector3(0, 0.145, -0.625)
	_check("eye: on the airframe", cam.global_position.distance_to(expected) < 1e-4, str(cam.global_position, expected))
	_check("eye: looks along the nose", (-cam.global_basis.z).dot(-body.z) > 0.9999)
	_check("eye: rolls with the airframe", cam.global_basis.x.dot(body.x) > 0.9999)
	_check("eye: near plane 3 cm", is_equal_approx(cam.near, 0.03))
	cam.free()


func _head_and_gimbal() -> void:
	var pair := _rig_with_eye()
	var cam: Camera3D = pair[0]
	var rig: RefCounted = pair[1]
	rig.set_view("cockpit")
	var at := Vector3(0, 40, 0)
	rig.fpv_head.mouse_drag(Vector2(300, 0)) # 45° right
	rig.update(at, Transform3D(Basis.IDENTITY, at), Basis.IDENTITY, 1.0 / 30.0, false, _flat)
	var forward := -cam.global_basis.z
	_check("head: a drag right looks right", forward.x > 0.65 and absf(forward.y) < 1e-3, str(forward))
	rig.reset_view()
	# A gimbal on the radio turns the FPV camera, never the pilot's head.
	rig.fpv_head.configure({camera_fpv_gimbal_pan_axis = 5, camera_fpv_gimbal_speed = "instant"})
	rig.fpv_head.update_gimbal(func(_axis: int) -> float: return 1.0, [], 1.0 / 30.0)
	rig.update(at, Transform3D(Basis.IDENTITY, at), Basis.IDENTITY, 1.0 / 30.0, false, _flat)
	forward = -cam.global_basis.z
	_check("head: the radio gimbal does not turn the eye", absf(forward.x) < 1e-4 and rig.fpv_head.offset().x != 0.0, str(forward, rig.fpv_head.offset()))
	cam.free()


func _wreck() -> void:
	var pair := _rig_with_eye()
	var cam: Camera3D = pair[0]
	var rig: RefCounted = pair[1]
	rig.set_view("cockpit")
	var at := Vector3(0, 0.2, -30)
	rig.update(at, Transform3D(Basis.IDENTITY, at), Basis.IDENTITY, 1.0 / 30.0, false, _flat)
	rig.focus(at, _flat)
	_check("wreck: the crash orbit hides the canopy", not rig.showing_cockpit() and rig.view == "cockpit")
	rig.reset()
	_check("wreck: a restart returns to the eye", rig.showing_cockpit())
	cam.free()


func _canopy() -> void:
	var size := Vector2(1920, 1080)
	_check("canopy: centred with the head forward", CanopyFrame.shift_for(Vector2.ZERO, 90.0) == Vector2.ZERO)
	var right := CanopyFrame.shift_for(Vector2(20, 0), 90.0)
	_check("canopy: slides left when looking right", right.x < 0.0 and right.y == 0.0, str(right))
	_check("canopy: a 20° turn at 90° slides a share of the pinhole", absf(right.x + CanopyFrame.PARALLAX_X * 0.5 * tan(deg_to_rad(20.0))) < 1e-6, str(right))
	var up := CanopyFrame.shift_for(Vector2(0, 15), 90.0)
	_check("canopy: slides down when looking up", up.y > 0.0, str(up))
	var far := CanopyFrame.shift_for(Vector2(170, -89), 90.0)
	_check("canopy: stops at its limit", far == Vector2(-CanopyFrame.MAX_SHIFT.x, -CanopyFrame.MAX_SHIFT.y), str(far))
	_check("canopy: the middle is glass", not CanopyFrame.covers(size, Vector2.ZERO, size * 0.5))
	_check("canopy: the corners are frame", CanopyFrame.covers(size, Vector2.ZERO, Vector2(2, size.y - 2))
		and CanopyFrame.covers(size, Vector2.ZERO, Vector2(size.x - 2, size.y - 2)))
	_check("canopy: the coaming hides the bottom", CanopyFrame.covers(size, Vector2.ZERO, Vector2(size.x * 0.5, size.y * 0.95)))
	_check("canopy: the sky above the nose is open", not CanopyFrame.covers(size, Vector2.ZERO, Vector2(size.x * 0.5, size.y * 0.1)))
	var outline := CanopyFrame.opening(size, Vector2.ZERO)
	var on_edge := true
	for p in outline:
		var q := (p / size - CanopyFrame.CENTRE) / CanopyFrame.HALF
		on_edge = on_edge and absf(pow(absf(q.x), CanopyFrame.SQUARENESS) + pow(absf(q.y), CanopyFrame.SQUARENESS) - 1.0) < 1e-4
	_check("canopy: the outline is the glass edge", outline.size() == CanopyFrame.SEGMENTS and on_edge)
	var frame := CanopyFrame.new()
	get_root().add_child(frame)
	frame.set_head(Vector2(20, 0), 90.0)
	_check("canopy: the layer records its slide", frame.evidence().shift[0] < 0.0 and frame.layer == CanopyFrame.LAYER)
	frame.free()


func _settings() -> void:
	_check("settings: cockpit is a first view", CameraSettings.errors({camera_view = "cockpit"}).is_empty())
	var cam := _camera()
	var rig := CameraRig.new(cam, SPAN)
	CameraSettings.apply_at_start(rig, {camera_view = "cockpit"})
	_check("settings: without an eye the flight starts in the pilot view", rig.view == "pilot")
	cam.free()
	var pair := _rig_with_eye()
	cam = pair[0]
	rig = pair[1]
	CameraSettings.apply_at_start(rig, {camera_view = "cockpit"})
	_check("settings: with one it starts in the cockpit", rig.view == "cockpit")
	cam.free()
