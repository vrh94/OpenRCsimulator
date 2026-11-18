# Step 19: truck tuning. The tune store, the optional experiment keys (gearing, steering lock, brakes) on the vehicle
# data, the driver aids (throttle limit, stability assist), and the garage's Tune truck panel saving and reloading a
# tune for one truck.
extends SceneTree

const Session := preload("res://sim/ground_vehicle/session.gd")
const VehicleData := preload("res://physics/ground_vehicle/vehicle_data.gd")
const TruckTuning := preload("res://vehicles/ground/truck_tuning.gd")
const DriverAids := preload("res://vehicles/ground/driver_aids.gd")
const Activity := preload("res://vehicles/ground/ground_scene.gd")
const FieldLoader := preload("res://data/field_loader.gd")
const M := preload("res://physics/math3d.gd")

const PATH := "user://test_truck_tuning.json"
const NEUTRAL := {"throttle": 0.0, "steering": 0.0, "brake": 0.0, "reverse": false, "armed": true}
const LAB := {"gravity_scale": 1.0, "grip_scale": 1.0, "spring_scale": 1.0, "damper_scale": 1.0, "ballast_kg": 0.0, "ballast_height_m": 0.15}

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
	TranslationServer.set_locale("en")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	_store()
	_data()
	_aids_unit()
	_assist_drives()
	await _garage()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
	print("%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _store() -> void:
	var clean := TruckTuning.sanitize({"gear_scale": 9.0, "stability": -1, "bogus": 1.0, "brake_scale": "x"})
	_check("sanitize clamps to the ranges, drops unknown keys and keeps stock for bad values",
		clean.gear_scale == 1.3 and clean.stability == 0.0 and not clean.has("bogus") and clean.brake_scale == 1.0
		and clean.size() == TruckTuning.SETTINGS.size())
	var tune := TruckTuning.stock()
	tune.gear_scale = 1.15
	tune.stability = 0.8
	var other := TruckTuning.stock()
	other.spring_scale = 1.4
	var saved := TruckTuning.save_for("x-maxx-8s", tune, PATH) and TruckTuning.save_for("mt8-bisonte", other, PATH)
	_check("tunes save and load per truck", saved and TruckTuning.load_for("x-maxx-8s", PATH) == tune
		and TruckTuning.load_for("mt8-bisonte", PATH).spring_scale == 1.4 and TruckTuning.load_for("monster-car-2", PATH) == TruckTuning.stock())
	TruckTuning.save_for("mt8-bisonte", TruckTuning.stock(), PATH)
	_check("saving the stock tune removes that truck's entry and keeps the others",
		not TruckTuning.load_all(PATH).has("mt8-bisonte") and TruckTuning.load_all(PATH).has("x-maxx-8s"))
	var knobs := TruckTuning.experiment(TruckTuning.stock())
	_check("a stock tune makes the plain six-knob experiment (no tuning keys)", knobs == LAB, str(knobs))
	_check("only changed tuning keys enter the experiment", TruckTuning.experiment(tune).has("gear_scale")
		and not TruckTuning.experiment(tune).has("steer_scale") and not TruckTuning.experiment(tune).has("stability"))


func _data() -> void:
	var base := VehicleData.load_vehicle("x-maxx-8s")
	var plain := VehicleData.with_experiment(base, LAB)
	var knobs := LAB.duplicate()
	knobs.merge({"gear_scale": 1.2, "steer_scale": 1.1, "brake_scale": 1.5})
	var tuned := VehicleData.with_experiment(base, knobs)
	var b: Dictionary = base.model
	var t: Dictionary = tuned.get("model", {})
	_check("electric gearing: no-load speed x1.2, wheel torque /1.2; steering x1.1; brakes x1.5", tuned.ok
		and is_equal_approx(t.drive_torque_fade_rad_s, b.drive_torque_fade_rad_s * 1.2)
		and is_equal_approx(t.drive_torque_per_wheel_nm, b.drive_torque_per_wheel_nm / 1.2)
		and is_equal_approx(t.max_steer_angle_rad, b.max_steer_angle_rad * 1.1)
		and is_equal_approx(t.brake_torque_per_wheel_nm, b.brake_torque_per_wheel_nm * 1.5), str(tuned.get("errors", [])))
	_check("a six-knob experiment's identity is unchanged by the optional keys (old checkpoints still match)",
		not str(plain.identity.settings_json).contains("gear_scale") and plain.identity.sha256 != tuned.identity.sha256)
	var nitro := VehicleData.load_vehicle("monster-car-2")
	var geared := VehicleData.with_experiment(nitro, knobs)
	_check("nitro gearing divides the gear ratio", geared.ok
		and is_equal_approx(geared.model.powertrain.gear_ratio, nitro.model.powertrain.gear_ratio / 1.2), str(geared.get("errors", [])))
	var bad := LAB.duplicate()
	bad.gear_scale = 1.5
	var unknown := LAB.duplicate()
	unknown.turbo = 1.0
	_check("out-of-range and unknown tuning keys are rejected", not VehicleData.with_experiment(base, bad).ok
		and not VehicleData.with_experiment(base, unknown).ok)
	# Taller gearing on the airfield grass: more top speed than stock.
	var stock_top := _top_speed({})
	var tall := LAB.duplicate()
	tall.gear_scale = 1.2
	var tall_top := _top_speed(tall)
	_check("taller gearing raises the X-Maxx's top speed (%.0f -> %.0f km/h)" % [stock_top * 3.6, tall_top * 3.6], tall_top > stock_top + 1.0)


func _top_speed(experiment: Dictionary) -> float:
	var s: Node = Session.new()
	root.add_child(s)
	s.prepare_airfield(FieldLoader.load_from(), {}, {}, "x-maxx-8s")
	if not experiment.is_empty():
		s.set_experiment(experiment)
	s.tick_once(NEUTRAL)
	s.resume()
	var cmd := NEUTRAL.duplicate()
	cmd.throttle = 1.0
	var top := 0.0
	for i in 240 * 14:
		s.tick_once(cmd)
		top = maxf(top, s.state_snapshot()[3])
	s.free()
	return top


func _aids_unit() -> void:
	var aids := DriverAids.new()
	var state := PackedFloat64Array()
	state.resize(31)
	state[6] = 1.0
	var cmd := {"throttle": 0.8, "steering": 0.4, "brake": 0.0, "reverse": false, "armed": true}
	_check("aids off pass the commands through unchanged", aids.apply(cmd, state, 1.0 / 240.0) == cmd and not aids.active())
	aids.throttle_limit = 0.5
	var limited := aids.apply(cmd, state, 1.0 / 240.0)
	_check("the throttle limit scales the throttle and nothing else", is_equal_approx(limited.throttle, 0.4)
		and limited.steering == 0.4 and limited.armed and cmd.throttle == 0.8)


func _assist_drives() -> void:
	# Full throttle with the wheel turned from a standstill on the grippy practice course rolls the X-Maxx over;
	# the full assist keeps it upright, and it still turns.
	var off := _launch(0.0)
	var on := _launch(1.0)
	_check("full throttle + steering from a standstill on the course: rolls over without the assist (%.0f deg)" % off.roll, off.roll > 90.0)
	_check("with the full assist it stays upright (%.0f deg roll), turns (%.0f deg) and reaches %.0f km/h" % [on.roll, on.turned, on.top * 3.6],
		on.roll < 20.0 and on.turned > 90.0 and on.top * 3.6 > 60.0)
	# The assist leaves an ordinary corner alone: 6 m/s at 40 % steering on the airfield turns as before.
	_check("the assist leaves a steady corner alone", absf(_corner(1.0) - _corner(0.0)) < 15.0)


func _launch(level: float) -> Dictionary:
	var s: Node = Session.new()
	root.add_child(s)
	s.prepare_default({}, "x-maxx-8s")
	s.tick_once(NEUTRAL)
	s.resume()
	var aids := DriverAids.new()
	aids.stability = level
	aids.configure(s.model_snapshot())
	var cmd := {"throttle": 1.0, "steering": 1.0, "brake": 0.0, "reverse": false, "armed": true}
	var roll := 0.0
	var top := 0.0
	var turned := 0.0
	var last := 0.0
	for i in 240 * 8:
		var st: PackedFloat64Array = s.state_snapshot()
		var e := M.q_to_euler(M.quat(st[6], st[7], st[8], st[9]))
		roll = maxf(roll, absf(rad_to_deg(e[2])))
		top = maxf(top, st[3])
		turned += absf(wrapf(e[0] - last, -PI, PI))
		last = e[0]
		s.tick_once(aids.apply(cmd, st, 1.0 / 240.0))
	s.free()
	return {"roll": roll, "top": top, "turned": rad_to_deg(turned)}


func _corner(level: float) -> float:
	var s: Node = Session.new()
	root.add_child(s)
	s.prepare_airfield(FieldLoader.load_from(), {}, {}, "x-maxx-8s")
	s.tick_once(NEUTRAL)
	s.resume()
	var aids := DriverAids.new()
	aids.stability = level
	aids.configure(s.model_snapshot())
	var turned := 0.0
	var last := 0.0
	for i in 240 * 10:
		var st: PackedFloat64Array = s.state_snapshot()
		var e := M.q_to_euler(M.quat(st[6], st[7], st[8], st[9]))
		var cmd := {"throttle": clampf(0.25 + 0.15 * (6.0 - st[3]), 0.0, 0.6), "steering": 0.4 if i > 240 * 5 else 0.0,
			"brake": 0.0, "reverse": false, "armed": true}
		s.tick_once(aids.apply(cmd, st, 1.0 / 240.0))
		if i > 240 * 5:
			turned += absf(wrapf(e[0] - last, -PI, PI))
		last = e[0]
	s.free()
	return rad_to_deg(turned)


func _garage() -> void:
	var tune := TruckTuning.stock()
	tune.gear_scale = 0.85
	tune.throttle_limit = 0.6
	tune.stability = 1.0
	TruckTuning.save_for("x-maxx-8s", tune, PATH)
	var activity: Node3D = _activity()
	_check("the garage starts with the saved tune applied", activity.startup_error.is_empty()
		and activity.dashboard.current_tuning() == tune and activity.driver_aids.stability == 1.0
		and is_equal_approx(activity.session.model_snapshot().drive_torque_fade_rad_s, VehicleData.load_vehicle("x-maxx-8s").model.drive_torque_fade_rad_s * 0.85),
		activity.startup_error)
	_check("the Tune truck panel is a garage control that opens and closes", activity.dashboard.tuning_button != null
		and not activity.dashboard.tuning.visible)
	activity.dashboard.show_tuning(true)
	_check("the gearing readout gives the no-load speed", str(activity.dashboard._slider_labels.gear_scale.text).contains("km/h no-load"),
		activity.dashboard._slider_labels.gear_scale.text)
	activity.dashboard.sliders.steer_scale.value = 1.2
	activity.dashboard.sliders.gear_scale.value = 1.0
	activity.dashboard.tuning_requested.emit(activity.dashboard.current_tuning())
	var stored := TruckTuning.load_for("x-maxx-8s", PATH)
	_check("Apply tuning restarts the run with the new data and saves it", activity.session.tick == 0 and activity.session.paused
		and stored.steer_scale == 1.2 and stored.gear_scale == 1.0
		and is_equal_approx(activity.session.model_snapshot().max_steer_angle_rad, VehicleData.load_vehicle("x-maxx-8s").model.max_steer_angle_rad * 1.2)
		and activity.dashboard.tuning_result.text.contains("Saved for this truck"))
	activity.dashboard.set_tuning(TruckTuning.stock())
	activity.dashboard.tuning_requested.emit(activity.dashboard.current_tuning())
	_check("Stock clears the experiment (stock identity) and the saved entry", activity.session.identities_snapshot().model == VehicleData.load_vehicle("x-maxx-8s").identity
		and not TruckTuning.load_all(PATH).has("x-maxx-8s") and not activity.driver_aids.active())
	activity.free()
	await process_frame


func _activity() -> Node3D:
	var activity: Node3D = Activity.new()
	activity.vehicle_id = "x-maxx-8s"
	activity.tuning_path = PATH
	activity.checkpoint_path = "user://test_truck_tuning_checkpoint.json"
	activity.use_practice_fixture = true
	activity.enable_audio = false
	activity.enable_course_visual = false
	root.add_child(activity)
	activity.set_physics_process(false)
	activity.set_process(false)
	return activity
