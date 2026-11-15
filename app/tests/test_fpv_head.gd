# FPV-5: onboard head-look, head tracking and the servo gimbal (render/camera/fpv_head.gd, onboard_view.gd aimed()).
#   - opentrack: datagrams parse (six little-endian doubles), malformed ones are refused; the first pose is straight
#     ahead, Backspace recentres, sensitivity scales, a silent tracker eases back to centre; a real UDP datagram on
#     127.0.0.1:4242 arrives; a second listener reports the port busy;
#   - mouse: right-drag turns right/up, clamped;
#   - gimbal: centre deadband, travel, reverse, servo speed limit, failsafe centring, flight axes refused;
#   - lens: pan about the airframe's up axis, then tilt (uptilt + look), then roll; the look does not lag on a soft mount;
#   - rig and settings: the drag reaches the lens only in the onboard view, Backspace recentres, defaults and refusals.
# Run: godot --headless --path . --script res://tests/test_fpv_head.gd
extends SceneTree

const FpvHead := preload("res://render/camera/fpv_head.gd")
const OnboardView := preload("res://render/camera/onboard_view.gd")
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
	_opentrack_parse()
	_tracking()
	await _udp()
	_mouse()
	_gimbal()
	_lens()
	_rig_and_settings()
	print("all %d FPV head checks passed" % _count if _failures == 0 else "%d of %d failed" % [_failures, _count])
	quit(1 if _failures > 0 else 0)


func _opentrack_parse() -> void:
	var bytes := FpvHead.opentrack_datagram(Vector3(1, 2, 3), 12.5, -7.25, 3.0)
	_check("opentrack: 48-byte datagram", bytes.size() == 48)
	_check("opentrack: angles parse", FpvHead.parse_opentrack(bytes) == Vector3(12.5, -7.25, 3.0))
	_check("opentrack: little-endian doubles (yaw at byte 24)", bytes.decode_double(24) == 12.5 and bytes[31] == 0x40)
	var short := bytes.slice(0, 40)
	_check("opentrack: a short datagram is refused", FpvHead.parse_opentrack(short) == null)
	var bad := bytes.duplicate()
	bad.encode_double(32, NAN)
	_check("opentrack: a non-finite angle is refused", FpvHead.parse_opentrack(bad) == null)


func _tracking() -> void:
	var head := FpvHead.new()
	head.feed_tracking(Vector3(30, 5, 0), 0.01)
	_check("tracking: the first pose is straight ahead", head.offset() == Vector3.ZERO)
	head.feed_tracking(Vector3(50, 15, -4), 0.01)
	_check("tracking: turns follow the head", head.offset().is_equal_approx(Vector3(20, 10, -4)), str(head.offset()))
	head.sensitivity = 2.0
	head.feed_tracking(Vector3(50, 15, -4), 0.01)
	_check("tracking: sensitivity scales", head.offset().is_equal_approx(Vector3(40, 20, -8)), str(head.offset()))
	head.sensitivity = 1.0
	head.feed_tracking(Vector3(170, 15, 0), 0.01)
	head.feed_tracking(Vector3(-170, 15, 0), 0.01) # crossed ±180: 20° further right, not 340° left
	_check("tracking: yaw wraps across ±180°", is_equal_approx(head.offset().x, 160.0), str(head.offset()))
	head.recentre()
	_check("tracking: Backspace takes the head pose as straight ahead", head.offset() == Vector3.ZERO)
	head.feed_tracking(Vector3(-140, 25, 0), 0.01)
	_check("tracking: turns from the new centre", head.offset().is_equal_approx(Vector3(30, 10, 0)), str(head.offset()))
	head.feed_tracking(null, 0.4)
	_check("tracking: holds through a short gap", head.offset().is_equal_approx(Vector3(30, 10, 0)))
	for i in 120:
		head.feed_tracking(null, 1.0 / 60.0)
	_check("tracking: a silent tracker eases back to centre", head.offset().length() < 0.5, str(head.offset()))


func _udp() -> void:
	var head := FpvHead.new()
	var opened := head.set_tracking("opentrack")
	_check("udp: listens on 127.0.0.1:4242", opened and head.tracking_status == "listening", head.tracking_status)
	if not opened:
		return
	var other := FpvHead.new()
	_check("udp: a second listener reports the port busy", not other.set_tracking("opentrack") and other.tracking_status == "port busy")
	var sender := PacketPeerUDP.new()
	sender.set_dest_address("127.0.0.1", FpvHead.OPENTRACK_PORT)
	sender.put_packet(FpvHead.opentrack_datagram(Vector3.ZERO, 0, 0, 0))
	sender.put_packet(FpvHead.opentrack_datagram(Vector3.ZERO, 15, -5, 0))
	for i in 30:
		await process_frame
		head.poll_tracking(1.0 / 60.0)
		if head.packets > 0:
			break
	_check("udp: a datagram arrives", head.packets >= 1 and head.tracking_status == "receiving", str(head.evidence()))
	head.set_tracking("off")
	_check("udp: off closes the listener", head.tracking_status == "" and other.set_tracking("opentrack"))
	other.close()
	sender.close()


func _mouse() -> void:
	var head := FpvHead.new()
	head.mouse_drag(Vector2(100, 0))
	_check("mouse: drag right looks right", is_equal_approx(head.offset().x, 100 * FpvHead.MOUSE_DEG_PER_PX))
	head.mouse_drag(Vector2(0, -100))
	_check("mouse: drag up looks up", is_equal_approx(head.offset().y, 100 * FpvHead.MOUSE_DEG_PER_PX))
	head.mouse_drag(Vector2(100000, 100000))
	_check("mouse: clamped", head.offset().x == FpvHead.YAW_LIMIT_DEG and head.offset().y == -FpvHead.PITCH_LIMIT_DEG)
	_check("mouse: recentre", head.recentre() and head.offset() == Vector3.ZERO)


func _gimbal() -> void:
	_check("gimbal: centre deadband", FpvHead.command(0.02, 90, false) == 0.0 and FpvHead.command(-0.029, 90, false) == 0.0)
	_check("gimbal: full travel", is_equal_approx(FpvHead.command(1.0, 90, false), 90.0) and is_equal_approx(FpvHead.command(-1.0, 45, false), -45.0))
	_check("gimbal: reverse", is_equal_approx(FpvHead.command(1.0, 90, true), -90.0))
	_check("gimbal: continuous past the deadband", FpvHead.command(0.031, 90, false) > 0.0 and FpvHead.command(0.031, 90, false) < 0.1)
	_check("gimbal: a missing channel commands the centre", FpvHead.command(NAN, 90, false) == 0.0)
	_check("gimbal: servo speed limit", is_equal_approx(FpvHead.slew(0.0, 90.0, 180.0, 0.1), 18.0) and FpvHead.slew(10.0, 12.0, 180.0, 0.1) == 12.0)
	_check("gimbal: instant servo", FpvHead.slew(0.0, 90.0, INF, 0.001) == 90.0)
	var head := FpvHead.new()
	head.configure({camera_fpv_gimbal_pan_axis = 4, camera_fpv_gimbal_tilt_axis = 5, camera_fpv_gimbal_pan_travel = 90,
		camera_fpv_gimbal_tilt_travel = 45, camera_fpv_gimbal_speed = "medium"})
	var axes := {4: 1.0, 5: -1.0}
	var read := func(axis: int) -> float: return float(axes.get(axis, NAN))
	head.update_gimbal(read, [0, 1, 2, 3], 0.1)
	_check("gimbal: servos move at their speed", head.gimbal.is_equal_approx(Vector2(18, -18)), str(head.gimbal))
	for i in 20:
		head.update_gimbal(read, [0, 1, 2, 3], 0.1)
	_check("gimbal: servos reach the commanded angles", head.gimbal.is_equal_approx(Vector2(90, -45)), str(head.gimbal))
	_check("gimbal: adds to the look", head.offset().is_equal_approx(Vector3(90, -45, 0)))
	head.update_gimbal(read, [0, 1, 2, 4], 0.1)
	_check("gimbal: a flight axis never drives it", is_equal_approx(head.gimbal_target.x, 0.0) and is_equal_approx(head.gimbal.x, 72.0), str(head.gimbal))
	axes.clear() # the radio is gone
	for i in 10:
		head.update_gimbal(read, [], 0.1)
	_check("gimbal: failsafe centring at servo speed", head.gimbal == Vector2.ZERO, str(head.gimbal))
	_check("gimbal: recentre leaves the servos alone", not head.recentre())


## The lens's forward (−z) direction for a look on a level airframe with `tilt` uptilt.
static func _forward(look: Vector3, tilt: float) -> Vector3:
	var view := OnboardView.new()
	view.configure(Vector3(0, 0.1, -0.5), "estimated")
	view.set_preferences(110.0, tilt, "off")
	view.look = look
	return -(view.placement(Transform3D.IDENTITY, Basis.IDENTITY, 16.0 / 9.0).basis as Basis).z


func _lens() -> void:
	var right := _forward(Vector3(30, 0, 0), 0.0)
	_check("lens: yaw right looks right", right.is_equal_approx(Vector3(sin(deg_to_rad(30.0)), 0, -cos(deg_to_rad(30.0)))), str(right))
	var up := _forward(Vector3(0, 20, 0), 5.0)
	_check("lens: look pitch adds to the uptilt", is_equal_approx(rad_to_deg(asin(up.y)), 25.0), str(up))
	var side := _forward(Vector3(90, 0, 0), 10.0)
	_check("lens: pan about the airframe's up axis (a pan-tilt gimbal)", side.is_equal_approx(Vector3(cos(deg_to_rad(10.0)), sin(deg_to_rad(10.0)), 0)), str(side))
	var view := OnboardView.new()
	view.configure(Vector3.ZERO, "estimated")
	view.set_preferences(110.0, 0.0, "off")
	view.look = Vector3(0, 0, 10)
	var cam_up := (view.placement(Transform3D.IDENTITY, Basis.IDENTITY, 16.0 / 9.0).basis as Basis).y
	_check("lens: roll is clockwise as the pilot sees it", cam_up.x > 0.0 and is_equal_approx(rad_to_deg(asin(cam_up.x)), 10.0), str(cam_up))
	_check("lens: straight down is the limit", is_equal_approx(rad_to_deg(asin(_forward(Vector3(0, -200, 0), 5.0).y)), -90.0))
	# Soft mount: the airframe attitude lags, the look does not.
	var soft := OnboardView.new()
	soft.configure(Vector3.ZERO, "estimated")
	soft.set_preferences(110.0, 0.0, "medium")
	soft.update(Transform3D.IDENTITY, Basis.IDENTITY, 16.0 / 9.0, 1.0 / 60.0, false)
	soft.look = Vector3(40, 0, 0)
	var turned := -(soft.update(Transform3D.IDENTITY, Basis.IDENTITY, 16.0 / 9.0, 1.0 / 60.0, false).basis as Basis).z
	_check("lens: the look does not lag through a soft mount", turned.is_equal_approx(Vector3(sin(deg_to_rad(40.0)), 0, -cos(deg_to_rad(40.0)))), str(turned))
	var rolled := Basis(Vector3.FORWARD, deg_to_rad(30.0))
	var lagging := soft.update(Transform3D.IDENTITY, rolled, 16.0 / 9.0, 1.0 / 60.0, false)
	var rigid := soft.placement(Transform3D.IDENTITY, rolled, 16.0 / 9.0)
	_check("lens: the airframe still lags through a soft mount", not (lagging.basis as Basis).is_equal_approx(rigid.basis))


func _rig_and_settings() -> void:
	var cam := PilotCamera.create(get_root(), { north = 0.0, east = 0.0, down = 0.0, eye_height = 1.7 })
	var rig := CameraRig.new(cam, 1.5)
	rig.onboard.configure(Vector3(0, 0.1, -0.5), "estimated")
	rig.drag(Vector2(100, 0))
	_check("rig: no head-look outside the onboard view", rig.fpv_head.mouse == Vector2.ZERO and not rig.drag_holds_cursor())
	rig.set_view("onboard")
	_check("rig: the onboard view holds the cursor while dragging", rig.drag_holds_cursor())
	rig.drag(Vector2(100, 0))
	rig.update(Vector3(0, 30, 0), Transform3D(Basis.IDENTITY, Vector3(0, 30, 0)), Basis.IDENTITY, 1.0 / 60.0, false, Callable())
	var fwd := -cam.basis.z
	_check("rig: the drag turns the onboard lens", fwd.x > 0.2 and rig.onboard.look.x > 0.0, str(fwd))
	_check("rig: evidence carries the head", (rig.evidence().onboard.head as Dictionary).has("gimbal"))
	rig.reset_view()
	_check("rig: Backspace looks straight ahead", rig.fpv_head.mouse == Vector2.ZERO)
	_check("settings: defaults validate", CameraSettings.errors({}).is_empty())
	var normal := CameraSettings.normalized({})
	_check("settings: defaults off (no tracking, no gimbal)", normal.camera_fpv_head_tracking == "off" and normal.camera_fpv_gimbal_pan_axis == -1
		and normal.camera_fpv_gimbal_tilt_axis == -1 and normal.camera_fpv_head_sensitivity == 1.0)
	for bad: Dictionary in [{camera_fpv_head_tracking = "trackir"}, {camera_fpv_head_sensitivity = 3.0}, {camera_fpv_gimbal_pan_axis = 10},
			{camera_fpv_gimbal_tilt_axis = "4"}, {camera_fpv_gimbal_pan_travel = 50}, {camera_fpv_gimbal_tilt_travel = 180},
			{camera_fpv_gimbal_speed = "warp"}, {camera_fpv_gimbal_invert_pan = 1}]:
		_check("settings: refuses %s" % str(bad), not CameraSettings.errors(bad).is_empty())
	CameraSettings.apply_at_start(rig, {camera_fpv_head_sensitivity = 1.5, camera_fpv_gimbal_pan_axis = 6, camera_fpv_gimbal_tilt_axis = 7,
		camera_fpv_gimbal_pan_travel = 120, camera_fpv_gimbal_speed = "fast", camera_fpv_gimbal_invert_tilt = true})
	var head = rig.fpv_head
	_check("settings: reach the head", head.sensitivity == 1.5 and head.pan_axis == 6 and head.tilt_axis == 7 and head.pan_travel_deg == 120.0
		and head.servo_speed == "fast" and head.invert_tilt and not head.invert_pan and head.tracking == "off")
	cam.free()
