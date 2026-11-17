# Step 18: the Traxxas X-Maxx 8S replica (research/x-maxx). Design-driven data and model, the published dimensions, the
# render rig against the data and the GLB, every paint, the Home roster, and how it drives: ride height, top speed near
# the 50+ mph claim, and steady corners without rolling over.
extends SceneTree

const Session := preload("res://sim/ground_vehicle/session.gd")
const VehicleData := preload("res://physics/ground_vehicle/vehicle_data.gd")
const XModel := preload("res://vehicles/ground/x_maxx_model.gd")
const GroundCatalog := preload("res://vehicles/ground/vehicle_catalog.gd")
const Roster := preload("res://app_state/vehicle_roster.gd")
const Preview := preload("res://ui/home_vehicle_preview.gd")
const VehiclePaint := preload("res://render/vehicle_paint.gd")
const FieldLoader := preload("res://data/field_loader.gd")
const M := preload("res://physics/math3d.gd")

const ID := "x-maxx-8s"
const NEUTRAL := {"throttle": 0.0, "steering": 0.0, "brake": 0.0, "reverse": false, "armed": true}

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
	var repo := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	for script: String in ["research/x-maxx/XM-02/build_model.py", "research/x-maxx/XM-01/derive_vehicle.py"]:
		var out: Array = []
		_check(script + " output is current", OS.execute("python3", [repo.path_join(script), "--check"], out, true) == 0, str(out))
	var loaded := VehicleData.load_vehicle(ID)
	_check("the data passes the production loader", loaded.ok, str(loaded.get("errors", [])))
	if not loaded.ok:
		_finish()
		return
	var m: Dictionary = loaded.model
	_data(m, repo)
	_rig(m)
	_registration()
	_ride()
	_top_speed()
	for item: Array in [[6.0, 0.4], [4.0, 1.0], [9.0, 0.2]]:
		_corner(item[0], item[1])
	_finish()


func _finish() -> void:
	print("%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _data(m: Dictionary, repo: String) -> void:
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/vehicles/ground/x_maxx_8s.json"))
	var source: Dictionary = raw.geometry_source
	_check("geometry source hashes match the design and the GLB",
		FileAccess.get_sha256(repo.path_join(source.spec_path)) == source.spec_sha256
		and FileAccess.get_sha256(repo.path_join(source.glb_path)) == source.glb_sha256)
	var x: PackedFloat64Array = m.corner_x_m
	var y: PackedFloat64Array = m.corner_y_m
	var total: float = float(m.sprung_mass_kg) + 4.0 * float(m.unsprung_mass_kg)
	_check("published: 480 mm wheelbase, 540 mm over the 8 in (203 mm) tires, 8.66 kg + packs, electric 4WD",
		is_equal_approx(x[0] - x[2], 0.48) and is_equal_approx(2.0 * y[1] + 0.102, 0.54) and is_equal_approx(m.tire_radius_m, 0.1015)
		and is_equal_approx(total, 9.86) and m.drive_configuration == "electric_4wd",
		"wb %s y %s r %s mass %s" % [x[0] - x[2], y[1], m.tire_radius_m, total])
	# T = T0 (1 - w/w0): w0 is the 8S, 1275 Kv no-load wheel speed through the derived ratio.
	var ground_free: float = float(m.drive_torque_fade_rad_s) * float(m.tire_radius_m)
	_check("drive line: free ground speed %.1f m/s (the 22.35 m/s claim is 95 %%), %.2f N m per wheel" % [ground_free, m.drive_torque_per_wheel_nm],
		absf(ground_free * 0.95 - 22.35) < 0.01 and float(m.drive_torque_per_wheel_nm) > 2.0)


func _rig(m: Dictionary) -> void:
	_check("render rig matches the data (stations, arm, travel)",
		is_equal_approx(XModel.WHEEL_X, m.corner_y_m[1]) and is_equal_approx(XModel.REST_Y, -m.wheel_center_rest_below_chassis_datum_m)
		and is_equal_approx(XModel.Z_FRONT, -m.corner_x_m[0]) and is_equal_approx(XModel.ARM_IN, m.arm_inner_offset_m)
		and is_equal_approx(XModel.ARM_L, m.arm_length_m) and is_equal_approx(XModel.TRAVEL_BUMP, m.travel_bump_m)
		and is_equal_approx(XModel.TRAVEL_DROOP, m.travel_droop_m))
	var scene: Node3D = (load(XModel.SCENE) as PackedScene).instantiate()
	var ok := true
	var detail := ""
	for c: String in XModel.CORNERS:
		var s := XModel.side_of(c)
		var za := XModel.axle_z(c)
		var want := {
			c + "_ArmLower": Vector3(s * XModel.ARM_IN, XModel.ARM_LOWER_Y, za),
			c + "_ArmUpper": Vector3(s * XModel.ARM_IN, XModel.ARM_UPPER_Y, za),
			c + "_Shock": Vector3(s * XModel.SHOCK_TOP.x, XModel.SHOCK_TOP.y, za),
			c + "_ShockRod": Vector3(0.0, -XModel.SHOCK_BODY_LEN, 0.0),
			c + "_Driveshaft": Vector3(s * XModel.DIFF_OUT_X, XModel.DIFF_Y, za),
			c + "_Suspension": Vector3(s * XModel.WHEEL_X, XModel.REST_Y, za),
		}
		for name: String in want:
			var node := scene.find_child(name, true, false) as Node3D
			if node == null or not node.position.is_equal_approx(want[name]):
				ok = false
				detail += "%s %s vs %s; " % [name, str(node.position) if node else "missing", want[name]]
	scene.free()
	_check("the XM-02 GLB's pivots sit where the render rig poses them", ok, detail)
	var painted := true
	for choice: Dictionary in VehiclePaint.choices(ID):
		var visual := XModel.build(str(choice.id))
		painted = painted and visual.ok and visual.skin == str(choice.id)
		if visual.ok:
			var state := PackedFloat64Array()
			state.resize(31)
			state[6] = 1.0
			state[13] = 0.03
			painted = painted and XModel.draw(visual, state, float(m.cg_height_above_chassis_datum_m))
			visual.root.free()
	_check("every stock paint (%d) builds, binds and draws" % VehiclePaint.choices(ID).size(), painted and VehiclePaint.choices(ID).size() == 4)


func _registration() -> void:
	var entry: Dictionary = GroundCatalog.entry(ID)
	_check("ground catalog, Home roster and preview offer it as an electric truck",
		GroundCatalog.contains(ID) and ID in GroundCatalog.IDS and not entry.nitro and Roster.has(ID)
		and Roster.family(ID) == Roster.GROUND and Preview.resource_path(ID) == XModel.SCENE)


func _session(on_airfield: bool) -> Node:
	var s: Node = Session.new()
	root.add_child(s)
	var ok: bool = s.prepare_airfield(FieldLoader.load_from(), {}, {}, ID) if on_airfield else s.prepare_default({}, ID)
	s.tick_once(NEUTRAL)
	_check("session prepares and arms (%s)" % ("airfield" if on_airfield else "practice course"), ok and s.resume(), s.load_error)
	return s


func _ride() -> void:
	var s := _session(false)
	for i in 480:
		s.tick_once(NEUTRAL)
	var st: PackedFloat64Array = s.state_snapshot()
	var m: Dictionary = s.model_snapshot()
	var clearance := -st[2] - float(m.cg_height_above_chassis_datum_m)
	_check("at rest: 23 mm sag on every corner and about 102 mm under the tub (%.1f mm)" % (clearance * 1000.0),
		absf(st[13] - 0.0229) < 0.002 and absf(st[16] - st[13]) < 1e-4 and absf(clearance - 0.102) < 0.006)
	s.free()


func _top_speed() -> void:
	var s := _session(true)
	var top := 0.0
	var cmd := NEUTRAL.duplicate()
	cmd.throttle = 1.0
	for i in 240 * 10:
		s.tick_once(cmd)
		var st: PackedFloat64Array = s.state_snapshot()
		top = maxf(top, Vector3(st[3], st[4], st[5]).length())
	_check("full throttle on the airfield grass: %.0f km/h (claim 80+ on pavement)" % (top * 3.6), top * 3.6 > 68.0 and top * 3.6 < 86.0)
	s.free()


func _corner(target: float, steer: float) -> void:
	var s := _session(true)
	var cmd := NEUTRAL.duplicate()
	var max_roll := 0.0
	var turned := 0.0
	var last := 0.0
	for i in 240 * 10:
		var st: PackedFloat64Array = s.state_snapshot()
		var v := Vector3(st[3], st[4], st[5]).length()
		var e := M.q_to_euler(M.quat(st[6], st[7], st[8], st[9]))
		cmd.throttle = clampf(0.25 + 0.15 * (target - v), 0.0, 0.6)
		cmd.steering = steer if i > 240 * 5 else 0.0
		s.tick_once(cmd)
		if i > 240 * 5:
			max_roll = maxf(max_roll, absf(rad_to_deg(e[2])))
			turned += absf(wrapf(e[0] - last, -PI, PI))
		last = e[0]
	_check("steady corner at %.0f m/s, %.0f %% steering: stays upright (roll %.1f deg) and turns %.0f deg in 5 s"
		% [target, steer * 100.0, max_roll, rad_to_deg(turned)], max_roll < 15.0 and rad_to_deg(turned) > 120.0)
	s.free()
