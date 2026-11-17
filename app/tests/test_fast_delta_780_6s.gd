# Step 17 (FD-03): the Dartwing 780 6S speed variant. Same d1 airframe and aerodynamics as the base Dartwing on a 6S
# speed drive; it must hold 360 km/h level on a fresh pack, stay stable at speed, and leave the hand at its own throw.
extends SceneTree

const Session := preload("res://sim/flight_session.gd")
const AircraftData := preload("res://physics/aircraft_data.gd")
const Catalog := preload("res://app_state/aircraft_catalog.gd")
const FieldLoader := preload("res://data/field_loader.gd")
const Weather := preload("res://physics/wind_config.gd")
const Trim := preload("res://physics/trim.gd")
const RB := preload("res://physics/rigid_body.gd")
const M := preload("res://physics/math3d.gd")

const ID := "fast-delta-780-6s"
const BASE := "fast-delta-780"
const TARGET_MPS := 100.0 # 360 km/h

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
	_generator()
	var model := _data()
	if not model.is_empty():
		_trim(model)
	_top_speed()
	_stability()
	_hand_launch()
	print("%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _generator() -> void:
	var repo := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	for script: String in ["research/fast-delta-780/FD-03/derive_speed.py", "research/fast-delta-780/FD-01/derive_physics.py"]:
		var out: Array = []
		var code := OS.execute("python3", [repo.path_join(script), "--check"], out, true)
		_check(script + " output is current", code == 0, str(out))


func _data() -> Dictionary:
	var entry := Catalog.entry(ID)
	_check("catalog: experimental, the Dartwing's visual family, both battery modes, pack default",
		entry.get("status") == Catalog.EXPERIMENTAL and Catalog.visual_family(ID) == BASE
		and Catalog.has_battery_mode(ID, "ideal") and Catalog.has_battery_mode(ID, "pack") and Catalog.default_battery_mode(ID) == "pack"
		and Catalog.hand_launch_supported(ID) and not Catalog.runway_supported(ID))
	var base: Dictionary = AircraftData.load_file(Catalog.data_for(BASE, "ideal"))
	var ideal := {}
	for mode: String in ["ideal", "pack"]:
		var data := AircraftData.load_file(Catalog.data_for(ID, mode))
		_check("%s data passes the production loader" % mode, data.ok, str(data.get("errors", [])))
		if not data.ok:
			continue
		var model: Dictionary = data.model
		_check("%s: the Dartwing's 0.78 m wing at 1.42 kg with its own 11 m/s throw" % mode, is_equal_approx(model.reference.b, 0.78)
			and absf(model.reference.S - 0.1443) < 1e-6 and absf(model.mass_kg - 1.42) < 1e-9 and is_equal_approx(model.hand_launch_speed, 11.0),
			"b %s S %s m %s throw %s" % [model.reference.b, model.reference.S, model.mass_kg, model.hand_launch_speed])
		if mode == "ideal":
			ideal = model
	if base.ok and not ideal.is_empty():
		# Same airframe, CG station and planform: every aerodynamic coefficient is the base Dartwing's, except the two that
		# carry the fins' height above the vertical CG (CYp, Clr), which the heavier 6S pack lowers slightly.
		var same := true
		for key: String in base.model.aero.keys():
			if typeof(base.model.aero[key]) not in [TYPE_FLOAT, TYPE_INT]:
				continue
			var a := float(base.model.aero[key])
			var b := float(ideal.aero.get(key, NAN))
			var ok := absf(a - b) <= 0.05 * absf(a) if key in ["CYp", "Clr"] else is_equal_approx(a, b)
			if not ok:
				same = false
				print("     differs: %s %s vs %s" % [key, a, b])
		_check("aerodynamic coefficients equal the base Dartwing's (same airframe; vertical-CG terms within 5 %)", same)
		_check("the base Dartwing keeps the shared hand-launch throw", not base.model.has("hand_launch_speed")
			and is_equal_approx(Session.hand_launch_speed(base.model), Session.HAND_LAUNCH_SPEED_MPS))
	return ideal


func _trim(model: Dictionary) -> void:
	var rows := []
	var ok := true
	for v: float in [model.start_speed, 40.0, 80.0, TARGET_MPS, 110.0]:
		var t := Trim.solve("level", v, model, 9.80665, model.controls.throw_rad)
		ok = ok and t.ok and float(t.throttle) > 0.0 and float(t.throttle) < 1.0
		rows.append("%.1f m/s thr %.3f" % [v, t.get("throttle", NAN)])
	_check("ideal 22.2 V bus: rudderless level trim from launch speed to 110 m/s inside the throttle range", ok, str(rows))
	print("     trim: ", rows)


func _session(mode: String, start_choice := "") -> Node:
	var session: Node = Session.new()
	if not start_choice.is_empty():
		session.start_choice = start_choice
	session.input_enabled = false
	session.crash_auto_restart = false
	session.setup(Catalog.data_for(ID, mode), ID)
	root.add_child(session)
	return session


func _state(session: Node) -> Dictionary:
	var s: PackedFloat64Array = session.sim.state
	var q := M.quat(s[RB.ATT], s[RB.ATT + 1], s[RB.ATT + 2], s[RB.ATT + 3])
	var e := M.q_to_euler(q)
	return {h = -s[RB.POS + 2], speed = Vector3(s[RB.VEL], s[RB.VEL + 1], s[RB.VEL + 2]).length(),
		vz = M.q_rotate(q, M.v3(s[RB.VEL], s[RB.VEL + 1], s[RB.VEL + 2]))[2], bank = e[2], q = s[RB.RATE + 1]}


func _top_speed() -> void:
	# Full throttle on a fresh pack from a 60 m/s level start, the pilot holding height and wings level. The height loop
	# softens with dynamic pressure, as a pilot's hand does.
	var session := _session("pack")
	session.trim_at(60.0, "level")
	session.set_start_altitude(300.0)
	session.reset()
	var h0: float = _state(session).h
	var dt: float = session.sim.dt()
	var top := 0.0
	var spread := 0.0
	var limited := false
	var crashed := false
	for i in roundi(15.0 / dt):
		var st := _state(session)
		var soft := pow(60.0 / maxf(60.0, st.speed), 2.0)
		var pitch := clampf(soft * (0.02 * (h0 - st.h) + 0.03 * st.vz), -0.5, 0.5)
		session.commands = {roll = clampf(-2.0 * st.bank, -1.0, 1.0), pitch = pitch, yaw = 0.0, throttle = 1.0}
		session.sim.inputs = session._inputs()
		if not session._session_after_input():
			crashed = true
			break
		session.sim.step()
		if i * dt > 3.0:
			top = maxf(top, st.speed)
			spread = maxf(spread, absf(st.h - h0))
			var values: PackedFloat64Array = session.sim.continuous
			limited = limited or float(session._battery_point(values[session._rotor_index()], values).get("esc_limit", 1.0)) < 1.0
	_check("fresh 6S pack, full throttle: holds %.0f km/h level (top %.1f m/s = %.0f km/h, height within %.1f m, no low-voltage cutoff)"
		% [TARGET_MPS * 3.6, top, top * 3.6, spread], not crashed and top >= TARGET_MPS and spread < 5.0 and not limited)
	session.free()


func _stability() -> void:
	# Hands-off at 110 m/s with a 0.15 s pitch-and-roll kick: the pitch disturbance dies out, nothing diverges.
	var session := _session("ideal")
	session.trim_at(110.0, "level")
	session.set_start_altitude(500.0)
	session.reset()
	var dt: float = session.sim.dt()
	var late := 0.0
	for i in roundi(6.0 / dt):
		var kick := 0.15 if i * dt > 1.0 and i * dt < 1.15 else 0.0
		session.commands = {roll = kick, pitch = kick, yaw = 0.0, throttle = session.start.throttle}
		session.sim.inputs = session._inputs()
		session.sim.step()
		if i * dt > 3.0:
			late = maxf(late, absf(_state(session).q))
	var st := _state(session)
	_check("110 m/s hands-off: a pitch kick damps out (|q| %.3f rad/s after 2 s), speed held (%.1f m/s)" % [late, st.speed],
		late < 0.1 and absf(st.speed - 110.0) < 6.0)
	session.free()


func _launch(how: String, throttle: float) -> Dictionary:
	var session := _session("pack", Session.START_HAND_LAUNCH)
	session.set_field(FieldLoader.load_from().field)
	session.setup_weather(Weather.defaults())
	session.reset()
	if how == "angle":
		session.flight_controller.set_mode("angle")
	var s: PackedFloat64Array = session.sim.state
	var release := Vector3(s[RB.VEL], s[RB.VEL + 1], s[RB.VEL + 2]).length()
	var start_height: float = -s[RB.POS + 2]
	for tick in 8 * 240:
		var roll := clampf(-3.0 * _state(session).bank, -1.0, 1.0) if how == "pilot" else 0.0
		session.commands = {roll = roll, pitch = 0.4, yaw = 0.0, throttle = throttle if tick < 360 else 1.0}
		session.sim.inputs = session._inputs()
		if not session._session_after_input():
			break
		session.sim.step()
	session._session_after_input()
	var out := {error = session.start_error, release = release, crashed = not session.crash.is_empty(), climb = _state(session).h - start_height}
	session.free()
	return out


func _hand_launch() -> void:
	# The aircraft's own 11 m/s throw (calm air, fresh pack). The pilot holds 40 % up, levels the wings against the torque and adds
	# full power after 1.5 s, or launches in angle mode.
	for item: Array in [["pilot", 0.6], ["pilot", 1.0], ["angle", 0.6], ["angle", 1.0]]:
		var r := _launch(item[0], item[1])
		_check("hand launch at the 11 m/s throw, %s, %.0f %% throttle: no crash, climbs away" % [item[0], item[1] * 100.0],
			r.error.is_empty() and absf(r.release - 11.0) < 1e-6 and not r.crashed and r.climb > 8.0, str(r))
