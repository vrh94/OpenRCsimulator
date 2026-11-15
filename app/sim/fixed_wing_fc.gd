## FC-1: a fixed-wing flight controller between the pilot's sticks and the servos, as on a real FPV airplane running
## INAV or ArduPilot. It reads only the simulated sensors a real FC has (attitude, body rates, airspeed, position and
## velocity from the rigid-body state) and writes stick-like commands {roll, pitch, yaw, throttle} in −1…1 / 0…1.
## The flight physics are untouched: the controller only moves the same surfaces the pilot moves. "manual" passes the
## sticks through unchanged, so a flight without a mode switch flies exactly as before.
##
## Modes (INAV / ArduPilot names):
##   manual   MANU / MANUAL  sticks straight to the surfaces
##   acro     ACRO / ACRO    stick = roll and pitch rate; centred sticks hold the attitude (gyro)
##   angle    ANGL / FBWA    stick = bank and pitch angle; centred sticks level the wings
##   horizon  HOR  / STAB    angle near centre, rate at full stick (rolls and loops possible)
##   alt_hold ALTH / FBWB    angle roll; pitch stick = climb rate, centred holds the altitude
##   cruise   CRUZ / CRUISE  altitude hold plus course hold; roll stick turns, release holds the new course
##   loiter   LOTR / LOITER  circles the point where it was engaged, at that altitude, with auto throttle
##   rth      RTH  / RTL     flies home (the launch point), climbs to a safe height, then circles over home
## Pure: no nodes. 64-bit floats. The session owns one and calls step() once per physics tick.
extends RefCounted

const RB := preload("res://physics/rigid_body.gd")
const M := preload("res://physics/math3d.gd")

const MODES: PackedStringArray = ["manual", "acro", "angle", "horizon", "alt_hold", "cruise", "loiter", "rth"]
## Names the pilot reads in menus and messages (translated by the caller).
const NAMES := {manual = "Manual", acro = "Acro", angle = "Angle (FBWA)", horizon = "Horizon (Stabilize)",
	alt_hold = "Altitude hold (FBWB)", cruise = "Cruise", loiter = "Loiter", rth = "Return to home"}
## OSD flight-mode text per OSD style, as the firmware prints it.
const OSD_LABELS := {
	inav = {manual = "MANU", acro = "ACRO", angle = "ANGL", horizon = "HOR", alt_hold = "ALTH", cruise = "CRUZ",
		loiter = "LOTR", rth = "RTH"},
	ardupilot = {manual = "MANU", acro = "ACRO", angle = "FBWA", horizon = "STAB", alt_hold = "FBWB", cruise = "CRUS",
		loiter = "LOIT", rth = "RTL"},
	betaflight = {manual = "", acro = "ACRO", angle = "ANGL", horizon = "HOR", alt_hold = "ALTH", cruise = "CRUZ",
		loiter = "LOTR", rth = "RTH"},
}
## The default modes on a three-position flight-mode switch (low, middle, high); Settings may change them.
const DEFAULT_SWITCH_MODES: PackedStringArray = ["manual", "angle", "cruise"]

const GRAVITY := 9.80665
## Stick limits of the self-levelling modes (INAV fw max bank / climb / dive angle style).
const MAX_BANK := deg_to_rad(45.0)
const MAX_PITCH_UP := deg_to_rad(25.0)
const MAX_PITCH_DOWN := deg_to_rad(30.0)
## Navigation limits: bank in automatic turns, climb and sink rates.
const NAV_BANK := deg_to_rad(30.0)
const MAX_CLIMB := 4.0 # m/s
const MAX_SINK := 4.0 # m/s
## Acro full-stick rates.
const ACRO_ROLL_RATE := deg_to_rad(180.0)
const ACRO_PITCH_RATE := deg_to_rad(90.0)
## Angle loop: commanded rate per radian of attitude error, and its rate limits.
const ANGLE_GAIN_ROLL := 4.0
const ANGLE_GAIN_PITCH := 3.0
const ANGLE_RATE_ROLL := deg_to_rad(120.0)
const ANGLE_RATE_PITCH := deg_to_rad(60.0)
## Rate loop gains (stick per rad/s), scaled by RATE_SPEED / airspeed: the surfaces' roll or pitch rate per stick
## grows with speed, so the loop gain stays about the same from a slow glider to a fast jet.
const RATE_SPEED := 20.0 # m/s
const RATE_P := Vector2(0.22, 0.30) # roll, pitch
const RATE_I := Vector2(1.2, 0.8)
## Feed-forward: an estimate of the stick a rate needs (rad/s per stick per m/s); deliberately low so the P and I
## terms finish the job on aircraft with more authority instead of overshooting.
const RATE_FF_AUTHORITY := Vector2(0.25, 0.20)
const RATE_I_LIMIT := 0.4
const SPEED_SCALE_LIMITS := Vector2(0.3, 2.5)
## Altitude loop: climb rate per metre of error, and the pitch per m/s of climb-rate error.
const ALT_GAIN := 0.5
const CLIMB_P := 0.03
const CLIMB_I := 0.02
const PITCH_TRIM_LIMIT := deg_to_rad(15.0)
## Course loop: bank per radian of course error.
const COURSE_GAIN := 1.0
## Auto throttle (loiter, RTH): throttle per m/s of airspeed error.
const SPEED_P := 0.06
const SPEED_I := 0.03
const MIN_NAV_SPEED := 10.0 # m/s
## RTH: the lowest height above home it flies back at.
const RTH_MIN_HEIGHT := 40.0
## Below this airspeed the controller has nothing to stabilise (on the ground, standing): it passes the sticks through.
const MIN_ACTIVE_SPEED := 4.0
const STICK_DEADBAND := 0.05

var mode := "manual"
## Home: the launch point (north, east, down), set on the first tick after a start.
var home := PackedFloat64Array()
## Navigation targets (diagnostics and OSD): altitude above datum (m, up), course (rad), loiter centre (n, e), radius.
var target_height := NAN
var target_course := NAN
var target_speed := NAN
var loiter_centre := PackedFloat64Array()
var loiter_radius := NAN
## "home" while RTH is still on its way, "orbit" once it circles over home.
var rth_phase := ""

var _rate_i := Vector2.ZERO
var _pitch_trim := 0.0
var _throttle_i := 0.0
var _engaged := false
var _last_tick := -1
var _last_output := {}


static func is_mode(id: String) -> bool:
	return id in MODES


static func osd_label(id: String, style: String) -> String:
	return str(OSD_LABELS.get(style, OSD_LABELS.inav).get(id, ""))


## The mode on a switch position. amount: the flight-mode AUX request 0…1 (two-position: 0 or 1; three-position:
## 0, 0.5, 1). switch_modes: the modes for low, middle and high.
static func switch_mode(amount: float, switch_modes: PackedStringArray) -> String:
	var modes := switch_modes if switch_modes.size() == 3 else DEFAULT_SWITCH_MODES
	var position := 0 if amount < 0.25 else (1 if amount < 0.75 else 2)
	return modes[position] if is_mode(modes[position]) else "manual"


func set_mode(id: String) -> bool:
	if not is_mode(id):
		return false
	if id != mode:
		mode = id
		_engaged = false # targets and integrators start from the aircraft's state at the next tick
	return true


## A new start (restart, new airplane): home is set again at the next tick; the mode stays.
func reset() -> void:
	home = PackedFloat64Array()
	_engaged = false
	_last_tick = -1
	_last_output = {}


## One controller tick. pilot: {roll, pitch, yaw, throttle} after rates and trims; s: rigid-body state (RB layout);
## airspeed: m/s; dt: s; tick: the simulation tick (a repeated tick reuses the last output without integrating, a
## smaller one is a new start); trim: the transmitter trims {roll, pitch} inside `pilot`. The stabilised modes read
## the sticks relative to the trims (a trimmed stick is centred, as after an FC's stick-centre calibration); manual
## keeps them. Returns the commands the servos receive.
func step(pilot: Dictionary, s: PackedFloat64Array, airspeed: float, dt: float, tick: int, trim: Dictionary = {}) -> Dictionary:
	if tick < _last_tick:
		reset()
	if s.size() < RB.SIZE:
		return pilot
	if home.is_empty():
		home = PackedFloat64Array([s[RB.POS], s[RB.POS + 1], s[RB.POS + 2]])
	if mode == "manual" or not is_finite(airspeed) or airspeed < MIN_ACTIVE_SPEED or not (dt > 0.0):
		_engaged = false
		_last_tick = tick
		_last_output = pilot
		return pilot
	if tick == _last_tick and not _last_output.is_empty():
		return _last_output
	_last_tick = tick
	var q := M.quat(s[RB.ATT], s[RB.ATT + 1], s[RB.ATT + 2], s[RB.ATT + 3])
	var euler := M.q_to_euler(q) # yaw, pitch, roll
	var v_ned := M.q_rotate(q, M.v3(s[RB.VEL], s[RB.VEL + 1], s[RB.VEL + 2]))
	var nav := {
		heading = float(euler[0]), pitch = float(euler[1]), roll = float(euler[2]),
		p = s[RB.RATE], q = s[RB.RATE + 1], r = s[RB.RATE + 2],
		height = -s[RB.POS + 2], climb = -v_ned[2], north = s[RB.POS], east = s[RB.POS + 1],
		ground_speed = sqrt(v_ned[0] * v_ned[0] + v_ned[1] * v_ned[1]), course = atan2(v_ned[1], v_ned[0]),
		airspeed = airspeed,
	}
	if nav.ground_speed < 3.0:
		nav.course = nav.heading
	if not _engaged:
		_engage(pilot, nav)
	var pr := clampf(float(pilot.get("roll", 0.0)) - float(trim.get("roll", 0.0)), -1.0, 1.0)
	var pp := clampf(float(pilot.get("pitch", 0.0)) - float(trim.get("pitch", 0.0)), -1.0, 1.0)
	var py := float(pilot.get("yaw", 0.0))
	var out := {roll = pr, pitch = pp, yaw = py, throttle = float(pilot.get("throttle", 0.0))}
	var scale := clampf(RATE_SPEED / airspeed, SPEED_SCALE_LIMITS.x, SPEED_SCALE_LIMITS.y)
	var rate_target := Vector2.ZERO # body p, q
	match mode:
		"acro":
			rate_target = Vector2(pr * ACRO_ROLL_RATE, pp * ACRO_PITCH_RATE)
		"angle":
			rate_target = _angle_rates(pr * MAX_BANK, _stick_pitch(pp), nav)
		"horizon":
			var level := _angle_rates(pr * MAX_BANK, _stick_pitch(pp), nav)
			var acro := Vector2(pr * ACRO_ROLL_RATE, pp * ACRO_PITCH_RATE)
			var w := clampf(maxf(absf(pr), absf(pp)), 0.0, 1.0)
			rate_target = level.lerp(acro, w * w)
		"alt_hold":
			rate_target = _angle_rates(pr * MAX_BANK, _altitude_pitch(pp, nav, dt), nav)
		"cruise":
			var bank := pr * MAX_BANK
			if absf(pr) > STICK_DEADBAND:
				target_course = nav.course # the course on release is held
			else:
				bank = _course_bank(target_course, nav)
			rate_target = _angle_rates(bank, _altitude_pitch(pp, nav, dt), nav)
		"loiter":
			rate_target = _angle_rates(_orbit_bank(nav), _altitude_pitch(0.0, nav, dt), nav)
			out.throttle = _auto_throttle(nav, dt)
		"rth":
			var bank := 0.0
			var to_home := Vector2(home[0] - nav.north, home[1] - nav.east)
			if rth_phase == "home" and to_home.length() <= loiter_radius:
				rth_phase = "orbit"
				loiter_centre = PackedFloat64Array([home[0], home[1]])
			if rth_phase == "orbit":
				bank = _orbit_bank(nav)
			else:
				target_course = atan2(to_home.y, to_home.x)
				bank = _course_bank(target_course, nav)
			rate_target = _angle_rates(bank, _altitude_pitch(0.0, nav, dt), nav)
			out.throttle = _auto_throttle(nav, dt)
	var stick := _rate_loop(rate_target, nav, scale, dt)
	out.roll = clampf(stick.x, -1.0, 1.0)
	out.pitch = clampf(stick.y, -1.0, 1.0)
	out.yaw = clampf(py, -1.0, 1.0)
	out.throttle = clampf(float(out.throttle), 0.0, 1.0)
	_last_output = out
	return out


## What the OSD and the HUD show: the mode and its navigation targets.
func status() -> Dictionary:
	return {mode = mode, home = home, target_height = target_height, target_course = target_course,
		target_speed = target_speed, loiter_radius = loiter_radius, rth_phase = rth_phase, engaged = _engaged}


func _engage(pilot: Dictionary, nav: Dictionary) -> void:
	_engaged = true
	_rate_i = Vector2.ZERO
	# The pitch the airplane needs for its present flight path, so altitude hold starts without a bump.
	_pitch_trim = clampf(nav.pitch - atan2(nav.climb, maxf(nav.airspeed, 1.0)), -PITCH_TRIM_LIMIT, PITCH_TRIM_LIMIT)
	_throttle_i = float(pilot.throttle)
	target_height = nav.height
	target_course = nav.course
	target_speed = maxf(nav.airspeed, MIN_NAV_SPEED)
	loiter_radius = clampf(target_speed * target_speed / (GRAVITY * tan(deg_to_rad(25.0))), 50.0, 400.0)
	loiter_centre = PackedFloat64Array([nav.north, nav.east])
	rth_phase = ""
	if mode == "loiter":
		# Circle the point where loiter was engaged: start on the circle, the centre to the right of the course.
		loiter_centre = PackedFloat64Array([nav.north - sin(nav.course) * loiter_radius, nav.east + cos(nav.course) * loiter_radius])
	elif mode == "rth":
		rth_phase = "home"
		target_height = maxf(nav.height, -home[2] + RTH_MIN_HEIGHT)


func _stick_pitch(stick: float) -> float:
	return stick * (MAX_PITCH_UP if stick > 0.0 else MAX_PITCH_DOWN)


## Bank and pitch targets → body rate targets (p, q), with the pitch rate a level turn needs.
func _angle_rates(bank: float, pitch: float, nav: Dictionary) -> Vector2:
	bank = clampf(bank, -MAX_BANK, MAX_BANK)
	pitch = clampf(pitch, -MAX_PITCH_DOWN, MAX_PITCH_UP)
	var p := clampf(ANGLE_GAIN_ROLL * wrapf(bank - nav.roll, -PI, PI), -ANGLE_RATE_ROLL, ANGLE_RATE_ROLL)
	var pitch_rate := clampf(ANGLE_GAIN_PITCH * (pitch - nav.pitch), -ANGLE_RATE_PITCH, ANGLE_RATE_PITCH)
	var roll: float = nav.roll
	var pitch_now: float = nav.pitch
	# Turn rate g·tan φ / V; its body pitch component keeps the nose up in the turn (coordinated-turn feed-forward).
	var turn_rate := GRAVITY * tan(clampf(roll, -1.3, 1.3)) / maxf(nav.airspeed, 1.0)
	var q := pitch_rate * cos(roll) + turn_rate * sin(roll) * cos(pitch_now)
	return Vector2(p, q)


## Altitude hold: the pitch stick asks for a climb rate (centred: hold the height at release).
func _altitude_pitch(stick: float, nav: Dictionary, dt: float) -> float:
	var climb_target := 0.0
	if absf(stick) > STICK_DEADBAND:
		climb_target = stick * (MAX_CLIMB if stick > 0.0 else MAX_SINK)
		target_height = nav.height
	else:
		climb_target = clampf(ALT_GAIN * (target_height - nav.height), -MAX_SINK, MAX_CLIMB)
	var error: float = climb_target - nav.climb
	_pitch_trim = clampf(_pitch_trim + CLIMB_I * error * dt, -PITCH_TRIM_LIMIT, PITCH_TRIM_LIMIT)
	var pitch_target := atan2(climb_target, maxf(nav.airspeed, 1.0)) + _pitch_trim + CLIMB_P * error
	return pitch_target


func _course_bank(course: float, nav: Dictionary) -> float:
	if not is_finite(course):
		return 0.0
	return clampf(COURSE_GAIN * wrapf(course - nav.course, -PI, PI), -NAV_BANK, NAV_BANK)


## Clockwise orbit of loiter_centre at loiter_radius: the tangent course, turned inward when outside the circle.
func _orbit_bank(nav: Dictionary) -> float:
	var dn: float = nav.north - loiter_centre[0]
	var de: float = nav.east - loiter_centre[1]
	var distance := sqrt(dn * dn + de * de)
	var bearing := atan2(de, dn) # from the centre to the airplane
	var correction := atan(2.0 * (distance - loiter_radius) / loiter_radius)
	target_course = wrapf(bearing + PI / 2.0 + correction, -PI, PI)
	var feed_forward := atan(nav.airspeed * nav.airspeed / (GRAVITY * loiter_radius))
	return clampf(feed_forward + COURSE_GAIN * wrapf(target_course - nav.course, -PI, PI), -NAV_BANK, NAV_BANK)


func _auto_throttle(nav: Dictionary, dt: float) -> float:
	var error: float = target_speed - nav.airspeed
	_throttle_i = clampf(_throttle_i + SPEED_I * error * dt, 0.0, 1.0)
	return clampf(_throttle_i + SPEED_P * error, 0.0, 1.0)


## Body rate targets → roll and pitch stick: feed-forward, P and I, scaled by speed.
func _rate_loop(target: Vector2, nav: Dictionary, scale: float, dt: float) -> Vector2:
	var error := Vector2(target.x - nav.p, target.y - nav.q)
	var speed := maxf(float(nav.airspeed), MIN_ACTIVE_SPEED)
	_rate_i.x = clampf(_rate_i.x + RATE_I.x * scale * error.x * dt, -RATE_I_LIMIT, RATE_I_LIMIT)
	_rate_i.y = clampf(_rate_i.y + RATE_I.y * scale * error.y * dt, -RATE_I_LIMIT, RATE_I_LIMIT)
	var ff := Vector2(target.x / (RATE_FF_AUTHORITY.x * speed), target.y / (RATE_FF_AUTHORITY.y * speed))
	return ff + Vector2(RATE_P.x * scale * error.x, RATE_P.y * scale * error.y) + _rate_i
