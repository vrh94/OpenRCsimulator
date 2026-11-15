# FPV-5: where the onboard lens points relative to its mount. Three sources add up, all presentation only (camera input;
# nothing reaches the session):
#   - mouse head-look: a right-button drag turns the lens (yaw, pitch); it stays where it was left until Backspace;
#   - head tracking: opentrack's UDP output (X-PERC-8, docs/plans/camera-views.md): one datagram of six little-endian
#     doubles (x, y, z in cm; yaw, pitch, roll in degrees) to port 4242 on this computer; only the rotations are used,
#     because the lens stays on the airframe. Backspace takes the current head pose as straight ahead. A tracker that
#     stops sending eases back to centre;
#   - servo gimbal: pan and tilt servos driven by two radio channels (the USB joystick axes the controller setup shows,
#     never a flight-control axis), with travel limits, a servo speed limit and centring when a channel is missing.
# Angles are degrees: yaw positive to the right, pitch positive up, roll positive clockwise as seen by the pilot.
extends RefCounted

## Mouse look: degrees per pixel at sensitivity 1, and the limits of the combined look.
const MOUSE_DEG_PER_PX := 0.15
const YAW_LIMIT_DEG := 180.0
const PITCH_LIMIT_DEG := 90.0
const ROLL_LIMIT_DEG := 90.0
const SENSITIVITIES: Array[float] = [0.5, 0.75, 1.0, 1.5, 2.0]
## Head tracking.
const TRACKING: Array[String] = ["off", "opentrack"]
const OPENTRACK_PORT := 4242
const OPENTRACK_ADDRESS := "127.0.0.1"
const OPENTRACK_BYTES := 48
## No datagram for this long (s): the tracked look eases back to centre with TRACK_RETURN_HALF_LIFE (s).
const TRACK_TIMEOUT_S := 0.5
const TRACK_RETURN_HALF_LIFE := 0.15
## Servo gimbal. Axes are the radio's joystick axes (0-based, as the controller setup labels them); -1 is none.
const AXES := 10
const PAN_TRAVELS: Array[int] = [30, 45, 60, 90, 120, 180]
const TILT_TRAVELS: Array[int] = [15, 30, 45, 60, 90]
## Servo speed limits (deg/s). A typical analog servo turns 60° in 0.1–0.2 s; a gimbal is usually slowed.
const SERVO_SPEEDS := { slow = 90.0, medium = 180.0, fast = 360.0, instant = INF }
const SERVO_SPEED_NAMES: Array[String] = ["slow", "medium", "fast", "instant"]
## Stick share around the channel centre that reads as exactly centred (a pot detent is rarely exact).
const DEADBAND := 0.03

var sensitivity := 1.0
var mouse := Vector2.ZERO # yaw, pitch (deg)
var tracking := "off"
## "", "listening", "receiving", "port busy"
var tracking_status := ""
var packets := 0
var pan_axis := -1
var tilt_axis := -1
var pan_travel_deg := 90.0
var tilt_travel_deg := 45.0
var servo_speed := "medium"
var invert_pan := false
var invert_tilt := false
## The servos' present angles (pan, tilt; deg) and where the channels command them.
var gimbal := Vector2.ZERO
var gimbal_target := Vector2.ZERO
var _udp: PacketPeerUDP
var _track_raw := Vector3.ZERO # yaw, pitch, roll as last received
var _track_zero := Vector3.ZERO
var _track := Vector3.ZERO # shown (recentred, scaled, eased out when stale)
var _track_age := INF


## The pilot's settings (CameraSettings keys).
func configure(config: Dictionary) -> void:
	sensitivity = float(config.get("camera_fpv_head_sensitivity", 1.0))
	set_tracking(str(config.get("camera_fpv_head_tracking", "off")))
	pan_axis = int(config.get("camera_fpv_gimbal_pan_axis", -1))
	tilt_axis = int(config.get("camera_fpv_gimbal_tilt_axis", -1))
	pan_travel_deg = float(config.get("camera_fpv_gimbal_pan_travel", 90))
	tilt_travel_deg = float(config.get("camera_fpv_gimbal_tilt_travel", 45))
	servo_speed = str(config.get("camera_fpv_gimbal_speed", "medium"))
	invert_pan = bool(config.get("camera_fpv_gimbal_invert_pan", false))
	invert_tilt = bool(config.get("camera_fpv_gimbal_invert_tilt", false))


## Opens or closes the opentrack listener. Returns true when the requested mode is active.
func set_tracking(mode: String) -> bool:
	if mode not in TRACKING:
		return false
	if mode == tracking and (mode == "off" or _udp != null):
		return true
	close()
	tracking = mode
	if mode == "off":
		tracking_status = ""
		return true
	_udp = PacketPeerUDP.new()
	if _udp.bind(OPENTRACK_PORT, OPENTRACK_ADDRESS) != OK:
		_udp = null
		tracking_status = "port busy"
		return false
	tracking_status = "listening"
	return true


func close() -> void:
	if _udp != null:
		_udp.close()
		_udp = null
	_track_age = INF


## A right-button drag (relative pixels): right turns the lens right, up turns it up.
func mouse_drag(relative: Vector2) -> void:
	mouse.x = clampf(mouse.x + relative.x * MOUSE_DEG_PER_PX * sensitivity, -YAW_LIMIT_DEG, YAW_LIMIT_DEG)
	mouse.y = clampf(mouse.y - relative.y * MOUSE_DEG_PER_PX * sensitivity, -PITCH_LIMIT_DEG, PITCH_LIMIT_DEG)


## Backspace: the mouse look returns to the mount and the tracker's present pose becomes straight ahead. The gimbal
## follows its channels (a physical stick position) and is not recentred. Returns true when anything changed.
func recentre() -> bool:
	var changed := mouse != Vector2.ZERO or _track != Vector3.ZERO
	mouse = Vector2.ZERO
	if _track_age <= TRACK_TIMEOUT_S:
		_track_zero = _track_raw
	_track = Vector3.ZERO
	return changed


## Reads this frame's opentrack datagrams (the newest one wins) and eases a stale tracker back to centre. dt: wall
## time since the last frame (s); the tracker is the pilot's head, so it keeps working while the flight is paused.
func poll_tracking(dt: float) -> void:
	if _udp == null:
		return
	var newest: Variant = null
	while _udp.get_available_packet_count() > 0:
		var parsed: Variant = parse_opentrack(_udp.get_packet())
		if parsed != null:
			newest = parsed
	feed_tracking(newest, dt)


## The tracker step without a socket (also used by tests): `angles` is a parsed datagram (yaw, pitch, roll) or null.
func feed_tracking(angles: Variant, dt: float) -> void:
	if angles is Vector3:
		if not _track_age < INF:
			_track_zero = angles # the first pose after a (re)start is straight ahead
		_track_raw = angles
		_track_age = 0.0
		packets += 1
		tracking_status = "receiving"
		var d: Vector3 = (_track_raw - _track_zero) * sensitivity
		_track = Vector3(clampf(_wrap(d.x), -YAW_LIMIT_DEG, YAW_LIMIT_DEG), clampf(d.y, -PITCH_LIMIT_DEG, PITCH_LIMIT_DEG),
			clampf(_wrap(d.z), -ROLL_LIMIT_DEG, ROLL_LIMIT_DEG))
		return
	if not is_finite(_track_age):
		return
	_track_age += maxf(dt, 0.0)
	if _track_age > TRACK_TIMEOUT_S:
		if tracking != "off" and tracking_status == "receiving":
			tracking_status = "listening"
		var k := 1.0 - pow(2.0, -maxf(dt, 0.0) / TRACK_RETURN_HALF_LIFE)
		_track = _track.lerp(Vector3.ZERO, k)


## An opentrack UDP datagram → Vector3(yaw, pitch, roll) in degrees, or null when malformed. The tracker's yaw and
## pitch are taken as positive right and up (opentrack's default output; an inverted axis is set in opentrack itself).
static func parse_opentrack(bytes: PackedByteArray) -> Variant:
	if bytes.size() != OPENTRACK_BYTES:
		return null
	var yaw := bytes.decode_double(24)
	var pitch := bytes.decode_double(32)
	var roll := bytes.decode_double(40)
	if not (is_finite(yaw) and is_finite(pitch) and is_finite(roll)):
		return null
	return Vector3(yaw, pitch, roll)


## One opentrack datagram (tests and the scratch sender): positions in cm, angles in degrees.
static func opentrack_datagram(position_cm: Vector3, yaw: float, pitch: float, roll: float) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(OPENTRACK_BYTES)
	for i in 3:
		bytes.encode_double(8 * i, position_cm[i])
	bytes.encode_double(24, yaw)
	bytes.encode_double(32, pitch)
	bytes.encode_double(40, roll)
	return bytes


## The servo gimbal for this frame. read_axis: Callable(axis) → the radio's present axis value in [−1, 1], or NAN
## when there is none (no radio, no sample yet); reserved: the flight-control axes, which never drive the gimbal.
## A missing channel commands the centre, so the servos return there at their speed (failsafe centring).
func update_gimbal(read_axis: Callable, reserved: Array, dt: float) -> void:
	gimbal_target = Vector2(
		command(_channel(read_axis, pan_axis, reserved), pan_travel_deg, invert_pan),
		command(_channel(read_axis, tilt_axis, reserved), tilt_travel_deg, invert_tilt))
	var rate: float = SERVO_SPEEDS.get(servo_speed, SERVO_SPEEDS.medium)
	gimbal = Vector2(slew(gimbal.x, gimbal_target.x, rate, dt), slew(gimbal.y, gimbal_target.y, rate, dt))


## A channel value (−1…1, NAN when missing) → the servo angle it commands (deg), with the centre deadband.
static func command(value: float, travel_deg: float, invert: bool) -> float:
	if not is_finite(value):
		return 0.0
	var v := clampf(value, -1.0, 1.0)
	var magnitude := maxf(absf(v) - DEADBAND, 0.0) / (1.0 - DEADBAND)
	return signf(v) * magnitude * travel_deg * (-1.0 if invert else 1.0)


## A servo moving from `at` toward `target` no faster than `rate` (deg/s).
static func slew(at: float, target: float, rate: float, dt: float) -> float:
	if not is_finite(rate):
		return target
	var step := rate * maxf(dt, 0.0)
	return at + clampf(target - at, -step, step)


## The combined look (yaw, pitch, roll; deg) from the mount's straight ahead.
func offset() -> Vector3:
	return Vector3(
		clampf(mouse.x + _track.x + gimbal.x, -YAW_LIMIT_DEG, YAW_LIMIT_DEG),
		clampf(mouse.y + _track.y + gimbal.y, -PITCH_LIMIT_DEG, PITCH_LIMIT_DEG),
		clampf(_track.z, -ROLL_LIMIT_DEG, ROLL_LIMIT_DEG))


## FPV-8: the pilot's own look (mouse and head tracking, no gimbal) for the cockpit view.
func head_offset() -> Vector3:
	return Vector3(
		clampf(mouse.x + _track.x, -YAW_LIMIT_DEG, YAW_LIMIT_DEG),
		clampf(mouse.y + _track.y, -PITCH_LIMIT_DEG, PITCH_LIMIT_DEG),
		clampf(_track.z, -ROLL_LIMIT_DEG, ROLL_LIMIT_DEG))


## The servos jump to their commanded angles (a new flight, a cut).
func snap_gimbal() -> void:
	gimbal = gimbal_target


func gimbal_enabled() -> bool:
	return pan_axis >= 0 or tilt_axis >= 0


func evidence() -> Dictionary:
	return { mouse = mouse, tracking = tracking, tracking_status = tracking_status, packets = packets, track = _track,
		pan_axis = pan_axis, tilt_axis = tilt_axis, gimbal = gimbal, gimbal_target = gimbal_target, servo_speed = servo_speed,
		offset = offset() }


func _channel(read_axis: Callable, axis: int, reserved: Array) -> float:
	if axis < 0 or axis >= AXES or reserved.has(axis) or not read_axis.is_valid():
		return NAN
	return float(read_axis.call(axis))


static func _wrap(deg: float) -> float:
	return wrapf(deg, -180.0, 180.0)
