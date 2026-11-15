# FC-1: the fixed-wing flight controller (sim/fixed_wing_fc.gd) between the sticks and the servos. Unit checks of the
# mode table, switch positions, OSD labels and the manual pass-through, then closed-loop flights through the real
# session (commands → FC → servos → physics) for every mode on a slow sport plane and a fast jet.
# Run: godot --headless --path . --script res://tests/test_fixed_wing_fc.gd
extends SceneTree

const FlightSession := preload("res://sim/flight_session.gd")
const Catalog := preload("res://app_state/aircraft_catalog.gd")
const FC := preload("res://sim/fixed_wing_fc.gd")
const CameraSettings := preload("res://render/camera/camera_settings.gd")
const DisplayPreferences := preload("res://app_state/display_preferences.gd")
const OsdModel := preload("res://render/overlays/fpv_osd_model.gd")
const ControllerActions := preload("res://input/controller_actions.gd")
const M := preload("res://physics/math3d.gd")
const RB := preload("res://physics/rigid_body.gd")

## Trim speeds: a slow electric sport plane and a fast turbine-style jet.
const PLANES := {"stik-electric-6s": 16.0, "sebart-avanti-s-a200-p100rx": 35.0}

var _failures := 0
var _count := 0


func _check(label: String, ok: bool, detail := "") -> void:
	_count += 1
	print(("ok   " if ok else "FAIL ") + label + ("" if ok or detail.is_empty() else "  " + detail))
	if not ok:
		_failures += 1


func _initialize() -> void:
	_units()
	_manual_pass_through()
	for id: String in PLANES:
		_flights(id, PLANES[id])
	print("%d checks, %d failures" % [_count, _failures])
	quit(1 if _failures > 0 else 0)


func _units() -> void:
	_check("settings offer exactly the controller's modes", Array(FC.MODES) == CameraSettings.FC_MODES)
	_check("every mode has a name and an OSD label in each style", FC.MODES.size() == 8 and Array(FC.MODES).all(func(m: String) -> bool:
		return FC.NAMES.has(m) and FC.OSD_LABELS.inav.has(m) and FC.OSD_LABELS.ardupilot.has(m) and FC.OSD_LABELS.betaflight.has(m)))
	var modes := PackedStringArray(["manual", "angle", "rth"])
	_check("switch positions: low, middle, high", FC.switch_mode(0.0, modes) == "manual" and FC.switch_mode(0.5, modes) == "angle"
		and FC.switch_mode(1.0, modes) == "rth" and FC.switch_mode(0.2, modes) == "manual" and FC.switch_mode(0.8, modes) == "rth")
	_check("a broken switch list falls back to the defaults", FC.switch_mode(1.0, PackedStringArray(["manual"])) == FC.DEFAULT_SWITCH_MODES[2])
	_check("an unknown mode on a switch position flies manual", FC.switch_mode(0.0, PackedStringArray(["warp", "angle", "cruise"])) == "manual")
	_check("OSD labels as the firmware prints them", FC.osd_label("angle", "ardupilot") == "FBWA" and FC.osd_label("angle", "inav") == "ANGL"
		and FC.osd_label("cruise", "inav") == "CRUZ" and FC.osd_label("rth", "ardupilot") == "RTL" and FC.osd_label("manual", "betaflight") == "")
	var fc := FC.new()
	_check("unknown modes are refused", not fc.set_mode("warp") and fc.mode == "manual")
	_check("the default switch is Manual / Angle / Cruise", CameraSettings.DEFAULTS.camera_fc_switch_low == "manual"
		and CameraSettings.DEFAULTS.camera_fc_switch_mid == "angle" and CameraSettings.DEFAULTS.camera_fc_switch_high == "cruise")
	var bad := CameraSettings.DEFAULTS.duplicate()
	bad.camera_fc_switch_high = "warp"
	_check("settings validation rejects an unknown switch mode", not CameraSettings.errors(bad).is_empty())
	_check("the switch positions are saved preferences", DisplayPreferences.CAMERA_FILE_KEYS.get("camera_fc_switch_low") == "fc_switch_low"
		and DisplayPreferences.CAMERA_FILE_KEYS.get("camera_fc_switch_high") == "fc_switch_high")
	_check("the Flight mode AUX channel serves airplanes and the quad",
		ControllerActions.aux_applies("flight_mode", ControllerActions.AIRPLANE_CAPABILITIES)
		and ControllerActions.aux_applies("flight_mode", ControllerActions.MULTIROTOR_CAPABILITIES))
	# The OSD mode element.
	var t := {ground_speed = 20.0, vertical_speed = 0.0, heading_deg = 0.0, pilot_north_m = 0.0, pilot_east_m = 0.0}
	t.flight_mode = "cruise"
	var v := OsdModel.values(t, {})
	var inav := OsdModel.items("inav", v, ["mode"], "metric")
	var ardu := OsdModel.items("ardupilot", v, ["mode"], "metric")
	_check("OSD shows the active mode (INAV CRUZ, ArduPilot CRUS)", inav.size() == 1 and inav[0].text == "CRUZ"
		and ardu.size() == 1 and ardu[0].text == "CRUS", str(inav) + str(ardu))
	t.flight_mode = "rth"
	var rth := OsdModel.items("betaflight", OsdModel.values(t, {}), ["mode"], "metric")
	_check("OSD: RTH is shown as a warning", rth.size() == 1 and rth[0].text == "RTH" and rth[0].severity == OsdModel.WARNING)
	t.erase("flight_mode")
	_check("OSD: no mode reported is manual (INAV MANU, Betaflight blank)",
		OsdModel.items("inav", OsdModel.values(t, {}), ["mode"], "metric")[0].text == "MANU"
		and OsdModel.items("betaflight", OsdModel.values(t, {}), ["mode"], "metric").is_empty())


func _session(id: String, speed: float, mode: String) -> Node:
	var session := FlightSession.new()
	session.setup(Catalog.entry(id).data)
	root.add_child(session)
	session.input_enabled = false
	var trim: Dictionary = session.trim_at(speed, "level")
	_check("%s trims at %.0f m/s" % [id, speed], trim.ok, str(trim.get("message", "")))
	session.set_start_altitude(200.0)
	session.reset()
	session.flight_controller.set_mode(mode)
	return session


func _nav(session: Node) -> Dictionary:
	var s: PackedFloat64Array = session.sim.state
	var q := M.quat(s[RB.ATT], s[RB.ATT + 1], s[RB.ATT + 2], s[RB.ATT + 3])
	var e := M.q_to_euler(q)
	var v := M.q_rotate(q, M.v3(s[RB.VEL], s[RB.VEL + 1], s[RB.VEL + 2]))
	return {h = -s[RB.POS + 2], n = s[RB.POS], e = s[RB.POS + 1], bank = rad_to_deg(e[2]), pitch = rad_to_deg(e[1]),
		course = rad_to_deg(atan2(v[1], v[0])), p = rad_to_deg(s[RB.RATE])}


## Flies `seconds` with sticks(t) → {roll, pitch, throttle}; returns a row (_nav) per `every` seconds.
func _fly(session: Node, seconds: float, sticks: Callable, every := 1.0) -> Array:
	var sim: Node = session.sim
	var rows := []
	var next := 0.0
	var t0: float = sim.time()
	for i in roundi(seconds / sim.dt()):
		var t: float = sim.time() - t0
		var c: Dictionary = sticks.call(t)
		session.commands = {roll = c.get("roll", 0.0), pitch = c.get("pitch", 0.0), yaw = 0.0,
			throttle = c.get("throttle", session.start.throttle)}
		sim.inputs = session._inputs()
		sim.step()
		if t >= next:
			next += every
			rows.append(_nav(session))
	return rows


func _manual_pass_through() -> void:
	var session := _session("stik-electric-6s", 16.0, "manual")
	var same := true
	for i in 120:
		session.commands = {roll = sin(i * 0.1) * 0.5, pitch = cos(i * 0.07) * 0.3, yaw = 0.1, throttle = 0.6}
		var flown: Dictionary = session.flown_commands()
		var inputs: PackedFloat64Array = session._inputs()
		same = same and inputs[0] == flown.roll and inputs[1] == flown.pitch and inputs[2] == flown.yaw and inputs[3] == flown.throttle
		session.sim.inputs = inputs
		session.sim.step()
	_check("manual: the servos get exactly the flown commands (flight unchanged)", same)
	_check("home is the launch point", session.flight_controller.home.size() == 3)
	session.free()


func _flights(id: String, speed: float) -> void:
	# Angle: full roll stick banks to the 45° limit; released, the wings level.
	var s := _session(id, speed, "angle")
	var rows := _fly(s, 8.0, func(t: float) -> Dictionary: return {roll = 1.0 if t < 3.0 else 0.0}, 0.5)
	_check("%s angle: full stick holds 45° bank" % id, absf(rows[5].bank - 45.0) < 5.0, str(rows[5].bank))
	_check("%s angle: released sticks level the wings" % id, absf(rows[-1].bank) < 3.0 and absf(rows[-1].pitch) < 5.0,
		"%.1f / %.1f" % [rows[-1].bank, rows[-1].pitch])
	s.free()
	# Acro: half stick asks for 90°/s; released, the attitude stays.
	s = _session(id, speed, "acro")
	rows = _fly(s, 3.0, func(t: float) -> Dictionary: return {roll = 0.5 if t < 0.8 else 0.0}, 0.2)
	_check("%s acro: half roll stick rolls near 90°/s" % id, absf(rows[3].p - 90.0) < 25.0, str(rows[3].p))
	_check("%s acro: released, the roll stops and the bank stays" % id, absf(rows[-1].p) < 10.0 and rows[-1].bank > 40.0,
		"p %.1f bank %.1f" % [rows[-1].p, rows[-1].bank])
	s.free()
	# Altitude hold (FBWB): a long turn without touching pitch keeps the height.
	s = _session(id, speed, "alt_hold")
	rows = _fly(s, 20.0, func(t: float) -> Dictionary: return {roll = 0.6 if t > 5.0 and t < 12.0 else 0.0})
	var spread: float = rows.map(func(r: Dictionary) -> float: return absf(r.h - 200.0)).max()
	_check("%s altitude hold: height within 2 m through a 27° turn" % id, spread < 2.0, str(spread))
	s.free()
	# Cruise: a roll-stick turn, released, holds the new course and the height.
	s = _session(id, speed, "cruise")
	rows = _fly(s, 30.0, func(t: float) -> Dictionary: return {roll = 0.7 if t > 3.0 and t < 6.0 else 0.0}, 2.0)
	var turned: float = wrapf(rows[-1].course - rows[0].course, -180.0, 180.0)
	var course_drift: float = absf(wrapf(rows[-1].course - rows[7].course, -180.0, 180.0))
	_check("%s cruise: the stick turned it, the new course holds" % id, turned > 20.0 and course_drift < 3.0,
		"turned %.1f drift %.1f" % [turned, course_drift])
	_check("%s cruise: height within 2 m" % id, absf(rows[-1].h - 200.0) < 2.0, str(rows[-1].h))
	s.free()
	# Loiter: circles at the engaged height with auto throttle, on its radius.
	s = _session(id, speed, "loiter")
	rows = _fly(s, 60.0, func(_t: float) -> Dictionary: return {throttle = 0.0}, 3.0)
	var fc: RefCounted = s.flight_controller
	var radius_error: float = rows.slice(5).map(func(r: Dictionary) -> float:
		return absf(Vector2(r.n - fc.loiter_centre[0], r.e - fc.loiter_centre[1]).length() - fc.loiter_radius)).max()
	_check("%s loiter: stays on its %.0f m circle (pilot throttle ignored)" % [id, fc.loiter_radius], radius_error < 0.1 * fc.loiter_radius,
		str(radius_error))
	_check("%s loiter: height within 2 m" % id, absf(rows[-1].h - 200.0) < 2.0, str(rows[-1].h))
	s.free()
	# RTH: from out over the field it turns back, flies home and circles over home.
	s = _session(id, speed, "manual")
	_fly(s, 20.0, func(_t: float) -> Dictionary: return {})
	fc = s.flight_controller
	var away := Vector2(_nav(s).n - fc.home[0], _nav(s).e - fc.home[1]).length()
	s.flight_controller.set_mode("rth")
	rows = _fly(s, 120.0, func(_t: float) -> Dictionary: return {throttle = 0.0}, 5.0)
	var home_distance := Vector2(rows[-1].n - fc.home[0], rows[-1].e - fc.home[1]).length()
	_check("%s RTH: back from %.0f m, circling over home" % [id, away], fc.rth_phase == "orbit"
		and home_distance < 1.2 * fc.loiter_radius and absf(rows[-1].h - 200.0) < 3.0, "%s %.0f m h %.1f" % [fc.rth_phase, home_distance, rows[-1].h])
	s.free()
