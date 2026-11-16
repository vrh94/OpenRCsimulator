# Step 15 (TB-01/TB-02): the twin-boom 1800, an original long-range FPV airplane in the Skyhunter 1800 class. Its physics
# and model are generated from assets/aircraft/twin-boom-1800/design.json; this checks the generators, the loaded data,
# the trim range, the hand launch, the flight-controller modes it was added for, and the built model.
# Run: godot --headless --path . --script res://tests/test_twin_boom_1800.gd
extends SceneTree

const Session := preload("res://sim/flight_session.gd")
const AircraftData := preload("res://physics/aircraft_data.gd")
const Catalog := preload("res://app_state/aircraft_catalog.gd")
const FieldLoader := preload("res://data/field_loader.gd")
const Weather := preload("res://physics/wind_config.gd")
const AirplaneBuilder := preload("res://render/airplane.gd")
const RB := preload("res://physics/rigid_body.gd")
const M := preload("res://physics/math3d.gd")

const ID := "twin-boom-1800"

var _checks := 0
var _failures := 0


func _check(label: String, ok: bool, detail := "") -> void:
	_checks += 1
	print(("ok   " if ok else "FAIL ") + label + ("" if ok or detail.is_empty() else "  " + detail))
	if not ok:
		_failures += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_generators()
	_data()
	_trim_range()
	_hand_launch()
	_flight_controller()
	_model()
	print("%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _generators() -> void:
	var repo := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	for script: String in ["research/twin-boom-1800/TB-01/derive_physics.py", "research/twin-boom-1800/TB-02/build_model.py"]:
		var out: Array = []
		var code := OS.execute("python3", [repo.path_join(script), "--check"], out, true)
		_check(script + " output is current", code == 0, str(out))


func _data() -> void:
	var entry := Catalog.entry(ID)
	_check("catalog: experimental, own visual family, both battery modes", entry.get("status") == Catalog.EXPERIMENTAL
		and Catalog.visual_family(ID) == ID and Catalog.has_battery_mode(ID, "ideal") and Catalog.has_battery_mode(ID, "pack")
		and Catalog.default_battery_mode(ID) == "pack")
	for mode: String in ["ideal", "pack"]:
		var data := AircraftData.load_file(Catalog.data_for(ID, mode))
		_check("%s data passes the production loader" % mode, data.ok, str(data.get("errors", [])))
		if not data.ok:
			continue
		var model: Dictionary = data.model
		_check("%s: 1.80 m span, 0.378 m² tapered wing, 2.6 kg" % mode, is_equal_approx(model.reference.b, 1.8)
			and absf(model.reference.S - 0.378) < 1e-6 and model.reference.chords.size() == 2 and absf(model.mass_kg - 2.6) < 1e-9,
			"b %s S %s m %s" % [model.reference.b, model.reference.S, model.mass_kg])
		_check("%s: pusher electric propeller, no landing gear, tolerant foam hull" % mode,
			model.propulsion.get("kind") == "electric_prop" and Catalog.hand_launch_supported(ID) and not Catalog.runway_supported(ID))


func _session(start_choice := "") -> Node:
	var session: Node = Session.new()
	if not start_choice.is_empty():
		session.start_choice = start_choice
	session.input_enabled = false
	session.crash_auto_restart = false
	session.setup(Catalog.entry(ID).data, ID)
	root.add_child(session)
	return session


func _trim_range() -> void:
	var session := _session()
	var rows := []
	var ok := true
	var last_pitch := INF
	for v: float in [11.0, 14.7, 18.0, 22.0, 26.0]:
		var t: Dictionary = session.trim_at(v, "level")
		ok = ok and t.ok and float(t.throttle) > 0.0 and float(t.throttle) < 1.0 and float(t.pitch_command) < last_pitch
		last_pitch = float(t.get("pitch_command", -INF))
		rows.append("%.0f m/s thr %.2f elev %.2f" % [v, t.get("throttle", NAN), t.get("pitch_command", NAN)])
	_check("trims level from 11 to 26 m/s inside the throttle range, more down elevator as it speeds up", ok, str(rows))
	print("     trim: ", rows)
	session.free()


func _hand_launch() -> void:
	var field: Dictionary = FieldLoader.load_from().field
	for weather: Dictionary in [Weather.defaults(), Weather.GENTLE_PRACTICE]:
		var session := _session(Session.START_HAND_LAUNCH)
		session.set_field(field)
		session.setup_weather(weather)
		session.reset()
		var ground: float = session.environment.terrain(session.sim.state[RB.POS], session.sim.state[RB.POS + 1])[0]
		var min_height := INF
		var height := 0.0
		for _tick in 6 * 240:
			if not session._session_after_input():
				break
			session.sim.step()
			height = -session.sim.state[RB.POS + 2] - ground
			min_height = minf(min_height, height)
		# 69 g/dm² against the MoonRunner's 42: after the 6.5 m/s throw the airplane sinks while the pusher accelerates it
		# (about 1.7 m in calm air, hands-off). The pod's belly is 0.10 m below the CG; it must stay off the grass.
		print("     hand launch, wind %s m/s: lowest CG height %.2f m, %.1f m after 6 s" % [str(weather.speed_mps), min_height, height])
		_check("hand launch (wind %s m/s): hands-off at full throttle, the belly clears the grass and it climbs away" % str(weather.speed_mps),
			session.start_error.is_empty() and session.crash.is_empty() and min_height > 0.12 and height > 8.0,
			"error '%s' crash %s min %.2f m, %.1f m after 6 s" % [session.start_error, str(session.crash), min_height, height])
		session.free()


func _nav(session: Node) -> Dictionary:
	var s: PackedFloat64Array = session.sim.state
	var q := M.quat(s[RB.ATT], s[RB.ATT + 1], s[RB.ATT + 2], s[RB.ATT + 3])
	var e := M.q_to_euler(q)
	var v := M.q_rotate(q, M.v3(s[RB.VEL], s[RB.VEL + 1], s[RB.VEL + 2]))
	return {h = -s[RB.POS + 2], bank = rad_to_deg(e[2]), course = rad_to_deg(atan2(v[1], v[0]))}


func _fly(session: Node, seconds: float, roll: Callable) -> Array:
	var rows := []
	for i in roundi(seconds / session.sim.dt()):
		session.commands = {roll = roll.call(i * session.sim.dt()), pitch = 0.0, yaw = 0.0, throttle = session.start.throttle}
		session.sim.inputs = session._inputs()
		session.sim.step()
		if i % 240 == 0:
			rows.append(_nav(session))
	rows.append(_nav(session))
	return rows


func _flight_controller() -> void:
	# Angle: full roll stick holds the 45° bank limit; released, the wings level.
	var session := _session()
	session.trim_at(16.0, "level")
	session.set_start_altitude(150.0)
	session.reset()
	session.flight_controller.set_mode("angle")
	var rows := _fly(session, 8.0, func(t: float) -> float: return 1.0 if t < 4.0 else 0.0)
	_check("FC angle: full stick holds 45° bank, released the wings level", absf(rows[4].bank - 45.0) < 6.0 and absf(rows[-1].bank) < 4.0,
		"%.1f / %.1f" % [rows[4].bank, rows[-1].bank])
	session.free()
	# Cruise: a 20 s straight leg holds height and course hands-off.
	session = _session()
	session.trim_at(16.0, "level")
	session.set_start_altitude(150.0)
	session.reset()
	session.flight_controller.set_mode("cruise")
	rows = _fly(session, 20.0, func(_t: float) -> float: return 0.0)
	_check("FC cruise: height within 3 m and course within 3° over 20 s", absf(rows[-1].h - rows[0].h) < 3.0
		and absf(wrapf(rows[-1].course - rows[1].course, -180.0, 180.0)) < 3.0,
		"h %.1f→%.1f course %.1f→%.1f" % [rows[0].h, rows[-1].h, rows[1].course, rows[-1].course])
	session.free()


func _model() -> void:
	var airplane := AirplaneBuilder.build(ID)
	_check("model builds through the shared imported-scene builder", airplane.get("root") is Node3D)
	if not airplane.get("root") is Node3D:
		return
	var rudders := 0
	for hinge: Variant in airplane.get("model_manifest", {}).get("bindings", {}).get("controls", {}).get("rudder", {}).get("hinges", []):
		rudders += 1
	_check("two rudders on the one rudder channel", rudders == 2, str(rudders))
	var gl: Node = airplane.root.find_child("TwinBoom1800", true, false)
	_check("propeller, two booms and both fins are in the scene", airplane.propeller is Node3D and gl != null
		and gl.find_child("booms", false, false) != null and gl.find_child("fin_left", false, false) != null
		and gl.find_child("fin_right", false, false) != null)
	airplane.root.free()
