# Step 16 (FD-01/FD-02): the fast delta 780 ("Dartwing 780"), an original swept flying-wing pusher in the FunJet
# speed-wing class. Its physics and model are generated from assets/aircraft/fast-delta-780/design.json; this checks the
# generators, the loaded data and the tailless strip law, the trim range up to its top speed, the hand launch, the
# flight-controller modes, and the built model with its two elevons.
# Run: godot --headless --path . --script res://tests/test_fast_delta_780.gd
extends SceneTree

const Session := preload("res://sim/flight_session.gd")
const AircraftData := preload("res://physics/aircraft_data.gd")
const Catalog := preload("res://app_state/aircraft_catalog.gd")
const FieldLoader := preload("res://data/field_loader.gd")
const Weather := preload("res://physics/wind_config.gd")
const AirplaneBuilder := preload("res://render/airplane.gd")
const Aero := preload("res://physics/aero.gd")
const Air := preload("res://physics/air_data.gd")
const Trim := preload("res://physics/trim.gd")
const Commands := preload("res://input/commands.gd")
const RB := preload("res://physics/rigid_body.gd")
const M := preload("res://physics/math3d.gd")

const ID := "fast-delta-780"

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
	var model := _data()
	if not model.is_empty():
		_tailless(model)
		_trim(model)
	_hand_launch()
	_flight_controller()
	_model()
	print("%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _generators() -> void:
	var repo := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	for script: String in ["research/fast-delta-780/FD-01/derive_physics.py", "research/fast-delta-780/FD-02/build_model.py"]:
		var out: Array = []
		var code := OS.execute("python3", [repo.path_join(script), "--check"], out, true)
		_check(script + " output is current", code == 0, str(out))


func _data() -> Dictionary:
	var entry := Catalog.entry(ID)
	_check("catalog: experimental, own visual family, both battery modes", entry.get("status") == Catalog.EXPERIMENTAL
		and Catalog.visual_family(ID) == ID and Catalog.has_battery_mode(ID, "ideal") and Catalog.has_battery_mode(ID, "pack")
		and Catalog.default_battery_mode(ID) == "pack")
	var ideal := {}
	for mode: String in ["ideal", "pack"]:
		var data := AircraftData.load_file(Catalog.data_for(ID, mode))
		_check("%s data passes the production loader" % mode, data.ok, str(data.get("errors", [])))
		if not data.ok:
			continue
		var model: Dictionary = data.model
		_check("%s: 0.78 m span, 0.1443 m² swept tapered wing, 0.875 kg" % mode, is_equal_approx(model.reference.b, 0.78)
			and absf(model.reference.S - 0.1443) < 1e-6 and model.reference.chords.size() == 2 and absf(model.mass_kg - 0.875) < 1e-9,
			"b %s S %s m %s" % [model.reference.b, model.reference.S, model.mass_kg])
		_check("%s: elevons on the tailless law, pusher, no landing gear" % mode, model.surfaces.has("tailless")
			and not model.surfaces.has("horizontal") and model.propulsion.get("kind") == "electric_prop"
			and Catalog.hand_launch_supported(ID) and not Catalog.runway_supported(ID))
		if mode == "ideal":
			ideal = model
	return ideal


func _coefficient(model: Dictionary, key: String, h: float, local: bool, index: int) -> float:
	var V := 20.0
	var rho := Air.RHO_SEA_LEVEL
	var values := []
	for sign: float in [1.0, -1.0]:
		var alpha := 0.03 + (sign * h if key == "alpha" else 0.0)
		var s := RB.make_state(M.v3(0, 0, -100), M.v3(V * cos(alpha), 0.0, V * sin(alpha)), M.q_from_euler(0, alpha, 0), M.v3(0, 0, 0))
		var d := {elevator = sign * h if key == "elevator" else 0.0, aileron_right = 0.0, aileron_left = 0.0, rudder = 0.0}
		var air: Dictionary = Air.compute(s, M.v3(0, 0, 0), rho)
		var loads: PackedFloat64Array = Aero._local_loads(s, air, d, model, rho) if local else Aero._global_loads(s, air, d, model, rho)
		var q := 0.5 * rho * V * V
		var lift := -(loads[2] * cos(alpha) - loads[0] * sin(alpha))
		values.append(lift / (q * model.reference.S) if index == 0 else loads[4] / (q * model.reference.S * model.reference.c))
	return (values[0] - values[1]) / (2.0 * h)


func _tailless(model: Dictionary) -> void:
	var tl: Dictionary = model.surfaces.tailless
	_check("the loader derived elevon effectiveness, station shift and camber couple",
		tl.has("tau") and tl.has("station_shift") and tl.has("moment_per_rad") and model.surfaces.has("wing_cm_ac"))
	# The Gilruth body term moves the oracle's neutral point about 3 % of the chord ahead of the wing's own; the rest is
	# the induced map against the MAC estimate. Both stay well inside the loader's quarter-chord bound.
	_check("the station shift stays inside 8 % of the chord (geometry agrees with the oracle's neutral point)",
		absf(float(tl.station_shift)) < 0.08 * float(model.reference.c), str(tl.station_shift))
	for item in [["CLa", "alpha", 0], ["Cma", "alpha", 1], ["CLde", "elevator", 0], ["Cmde", "elevator", 1]]:
		var oracle := _coefficient(model, item[1], 0.01, false, item[2])
		var local := _coefficient(model, item[1], 0.01, true, item[2])
		_check("strip model reproduces the oracle's %s" % item[0], absf(local - oracle) <= 0.02 * absf(oracle) + 1e-4,
			"local %.5f oracle %.5f" % [local, oracle])


func _trim(model: Dictionary) -> void:
	var rows := []
	var ok := true
	for v: float in [model.start_speed, 20.0, 30.0, 40.0, 50.0]:
		var t := Trim.solve("level", v, model, 9.80665, model.controls.throw_rad)
		ok = ok and t.ok and t.rudder == 0.0 and float(t.throttle) > 0.0 and float(t.throttle) < 1.0
		rows.append("%.1f m/s thr %.2f elev %.2f°" % [v, t.get("throttle", NAN), rad_to_deg(t.get("elevator", NAN))])
	_check("rudderless level trim from launch speed to 50 m/s inside the throttle range", ok, str(rows))
	print("     trim: ", rows)
	var t := Trim.solve("level", 50.0, model, 9.80665, model.controls.throw_rad)
	var commands := Commands.neutral_commands()
	commands.pitch = t.pitch_command
	commands.roll = t.roll_command
	var surfaces := Commands.surface_deflections_deg(commands, model.controls.throw_deg)
	_check("the radio mix of the 50 m/s trim reproduces the trimmed elevons",
		absf(deg_to_rad(-surfaces.elevator) - t.elevator) < 1e-9 and absf(deg_to_rad(-surfaces.aileron_right) - t.aileron) < 1e-9)
	var top := Trim.solve("level", 60.0, model, 9.80665, model.controls.throw_rad)
	_check("top level speed between 50 and 60 m/s (the class flies about 61 m/s on a 6x5.5; ours turns a borrowed 7x6)",
		not top.ok and String(top.get("message", "")).contains("throttle"), str(top.get("message", "")))
	var glide := Trim.solve("glide", 15.0, model, 9.80665, model.controls.throw_rad)
	_check("power-off glide trims with a flying-wing glide (L/D 6-15)", glide.ok and -1.0 / tan(glide.gamma) > 6.0 and -1.0 / tan(glide.gamma) < 15.0,
		str(glide.get("gamma")))


func _session(start_choice := "") -> Node:
	var session: Node = Session.new()
	if not start_choice.is_empty():
		session.start_choice = start_choice
	session.input_enabled = false
	session.crash_auto_restart = false
	session.setup(Catalog.entry(ID).data, ID)
	root.add_child(session)
	return session


func _launch(weather: Dictionary, how: String, up := 0.0) -> Dictionary:
	var session := _session(Session.START_HAND_LAUNCH)
	session.set_field(FieldLoader.load_from().field)
	session.setup_weather(weather)
	session.reset()
	if how == "angle":
		session.flight_controller.set_mode("angle")
	var start_height: float = -session.sim.state[RB.POS + 2]
	for _tick in 6 * 240:
		var bank: float = _nav(session).bank
		# "pilot": a thumb that only holds the wings level against the torque (no pitch input); "angle": hands off in
		# the flight controller's self-levelling mode; "manual": hands off.
		var roll := clampf(-3.0 * deg_to_rad(bank), -1.0, 1.0) if how == "pilot" else 0.0
		session.commands = {roll = roll, pitch = up, yaw = 0.0, throttle = 1.0}
		session.sim.inputs = session._inputs()
		if not session._session_after_input(): # ground contact and crash detection, as in the game loop
			break
		session.sim.step()
	session._session_after_input()
	var s: PackedFloat64Array = session.sim.state
	var out := {error = session.start_error, crashed = not session.crash.is_empty(), climb = -s[RB.POS + 2] - start_height,
		speed = Vector3(s[RB.VEL], s[RB.VEL + 1], s[RB.VEL + 2]).length()}
	session.free()
	return out


func _hand_launch() -> void:
	# 60 g/dm² (the class figure) thrown at the shared 6.5 m/s, below the 10.4 m/s stall, at full power. Hands off it
	# drops into the grass within a second; held with some up elevator (and, in manual, the wings levelled against the
	# propeller torque) it accelerates away, as real speed wings are launched. Angle mode levels the wings itself.
	var manual := _launch(Weather.defaults(), "manual")
	print("     hand launch hands-off in manual: crashed %s" % manual.crashed)
	for weather: Dictionary in [Weather.defaults(), Weather.GENTLE_PRACTICE]:
		var angle := _launch(weather, "angle", 0.35)
		_check("hand launch (wind %s m/s) in angle mode with 35 %% up stick: no crash, climbs away past 30 m/s" % str(weather.speed_mps),
			angle.error.is_empty() and not angle.crashed and angle.climb > 8.0 and angle.speed > 30.0, str(angle))
	for up: float in [0.2, 0.5]:
		var pilot := _launch(Weather.defaults(), "pilot", up)
		_check("hand launch in manual with %.0f %% up elevator, the pilot levelling the wings: no crash, climbs away" % (up * 100.0),
			pilot.error.is_empty() and not pilot.crashed and pilot.climb > 8.0, str(pilot))


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
	session.trim_at(25.0, "level")
	session.set_start_altitude(150.0)
	session.reset()
	session.flight_controller.set_mode("angle")
	var rows := _fly(session, 8.0, func(t: float) -> float: return 1.0 if t < 4.0 else 0.0)
	_check("FC angle: full stick holds 45° bank, released the wings level", absf(rows[4].bank - 45.0) < 6.0 and absf(rows[-1].bank) < 4.0,
		"%.1f / %.1f" % [rows[4].bank, rows[-1].bank])
	session.free()
	# Cruise: a 20 s straight leg holds height and course hands-off.
	session = _session()
	session.trim_at(25.0, "level")
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
	var controls: Dictionary = airplane.get("model_manifest", {}).get("bindings", {}).get("controls", {})
	_check("the model binds exactly the two elevon roles", controls.keys().size() == 2 and controls.has("elevon_left") and controls.has("elevon_right"),
		str(controls.keys()))
	var gl: Node = airplane.root.find_child("FastDelta780", true, false)
	_check("propeller, centre body and both fins are in the scene", airplane.propeller is Node3D and gl != null
		and gl.find_child("fuselage", false, false) != null and gl.find_child("fin_left", false, false) != null
		and gl.find_child("fin_right", false, false) != null)
	airplane.root.free()
