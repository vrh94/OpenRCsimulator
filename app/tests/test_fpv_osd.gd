# FPV-6: the fixed-wing FPV OSD (render/overlays/fpv_osd_model.gd, fpv_osd.gd).
#   - values come only from the telemetry snapshot and the battery sensors; absent sources hide their elements;
#   - home: distance and arrow toward the pilot station; altitude above the station's ground;
#   - styles: Betaflight, INAV and ArduPilot place and label the elements differently; off draws nothing;
#   - severities: battery % and cell voltage bands, battery alarms in the warning slot;
#   - horizon: pitch moves it down, the uptilt offsets it, bank turns it;
#   - settings: defaults, refusals, the rig receives them; the layer feeds and resets.
# Run: godot --headless --path . --script res://tests/test_fpv_osd.gd
extends SceneTree

const Model := preload("res://render/overlays/fpv_osd_model.gd")
const FpvOsd := preload("res://render/overlays/fpv_osd.gd")
const CameraSettings := preload("res://render/camera/camera_settings.gd")
const CameraRig := preload("res://render/camera/camera_rig.gd")
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
	_values()
	_styles()
	_severity()
	_horizon()
	_settings()
	await _layer()
	print("all %d FPV OSD checks passed" % _count if _failures == 0 else "%d of %d failed" % [_failures, _count])
	quit(1 if _failures > 0 else 0)


## A telemetry snapshot 300 m north of the pilot, heading east, 50 m above a station at 120 m.
static func _telemetry() -> Dictionary:
	return {ground_speed = 20.0, airspeed = 22.0, height_datum = 170.0, home_up_m = 120.0, pilot_north_m = 300.0,
		pilot_east_m = 0.0, heading_deg = 90.0, time_s = 125.0, pitch_deg = 3.0, bank_deg = 0.0}


static func _battery(pct := 80.0, cell := 3.9, alarms: Array[String] = []) -> Dictionary:
	return {valid = true, pack_voltage_v = cell * 4.0, cell_avg_v = cell, remaining_pct = pct, current_a = 12.34,
		used_mah = 456, alarms = alarms}


func _values() -> void:
	var v := Model.values(_telemetry(), _battery())
	_check("values: home distance is horizontal", is_equal_approx(float(v.home_distance_m), 300.0))
	_check("values: home arrow points back (south while heading east: right turn of 90°)", is_equal_approx(float(v.home_relative_deg), 90.0), str(v.home_relative_deg))
	_check("values: altitude above the station's ground", is_equal_approx(float(v.altitude_m), 50.0))
	_check("values: GPS speed in level flight is the ground speed", float(v.speed_mps) == 20.0)
	# A steep dive: the horizontal ground speed falls while the plane speeds up; the 3D speed shows the speed-up.
	var dive := _telemetry()
	dive.ground_speed = 10.0
	dive.vertical_speed = -24.0
	_check("values: GPS speed is 3D (it rises in a dive)", is_equal_approx(float(Model.values(dive, _battery()).speed_mps), 26.0),
		str(Model.values(dive, _battery()).speed_mps))
	_check("values: battery from the sensors", float(v.voltage_v) == 15.6 and float(v.current_a) == 12.34 and float(v.used_mah) == 456.0)
	var bare := Model.values(_telemetry(), {})
	_check("values: no battery, no battery numbers", is_nan(float(bare.voltage_v)) and is_nan(float(bare.remaining_pct)))
	_check("values: no link model, no link figure", is_nan(float(bare.link_pct)))
	var ids := Model.items("betaflight", bare, Model.ELEMENTS, "metric").map(func(i: Dictionary) -> String: return i.id)
	_check("values: absent sources hide their elements", "voltage" not in ids and "current" not in ids and "link" not in ids
		and "battery_pct" not in ids and "speed" in ids and "home" in ids, str(ids))
	var linked := Model.values(_telemetry(), {}, {quality_pct = 87.0})
	_check("values: a link model's quality shows", Model.items("inav", linked, ["link"], "metric")[0].text == "LQ 87")


static func _text(items: Array, id: String) -> String:
	for i: Dictionary in items:
		if i.id == id:
			return str(i.text)
	return ""


static func _cell(items: Array, id: String) -> Vector2i:
	for i: Dictionary in items:
		if i.id == id:
			return i.cell
	return Vector2i(-1, -1)


func _styles() -> void:
	var v := Model.values(_telemetry(), _battery())
	var bf := Model.items("betaflight", v, Model.ELEMENTS, "metric")
	var inav := Model.items("inav", v, Model.ELEMENTS, "metric")
	var ap := Model.items("ardupilot", v, Model.ELEMENTS, "metric")
	_check("styles: Betaflight voltage with battery icon", _text(bf, "voltage") == "15.6V" and bf.filter(func(i: Dictionary) -> bool: return i.id == "voltage")[0].icon == "battery")
	_check("styles: INAV adds the cell voltage", _text(inav, "voltage") == "15.6V 3.90V", _text(inav, "voltage"))
	_check("styles: ArduPilot labels the battery", _text(ap, "voltage") == "BAT 15.6V")
	_check("styles: timers", _text(bf, "timer") == "02:05" and _text(inav, "timer") == "FLY 02:05" and _text(ap, "timer") == "FLT 02:05",
		"%s %s %s" % [_text(bf, "timer"), _text(inav, "timer"), _text(ap, "timer")])
	_check("styles: speed and altitude", _text(bf, "speed") == "72KM/H" and _text(bf, "altitude") == "ALT 50.0M" and _text(ap, "speed") == "GS 72KM/H",
		"%s %s" % [_text(bf, "speed"), _text(bf, "altitude")])
	_check("styles: imperial units", _text(Model.items("betaflight", v, ["speed", "altitude"], "imperial"), "speed") == "45MPH")
	_check("styles: home distance with the arrow", _text(bf, "home") == "300M" and _text(ap, "home") == "H 300M")
	_check("styles: heading formats", _text(bf, "heading") == "090" and _text(inav, "heading") == "090°" and _text(ap, "heading") == "HDG 090")
	_check("styles: manual mode on INAV and ArduPilot only", _text(inav, "mode") == "MANU" and _text(ap, "mode") == "MANU" and _text(bf, "mode") == "")
	_check("styles: current and mAh", _text(bf, "current") == "12.3A  456MAH" and _text(ap, "current") == "12.3A  456mAh", _text(bf, "current"))
	_check("styles: places differ (ArduPilot battery at the top, Betaflight at the bottom)", _cell(ap, "voltage").y < 4 and _cell(bf, "voltage").y > 12)
	_check("styles: every cell inside the grid", (bf + inav + ap).all(func(i: Dictionary) -> bool:
		return i.cell.x >= 0 and i.cell.x < Model.COLS and i.cell.y >= 0 and i.cell.y < Model.ROWS))
	_check("styles: off has nothing", Model.items("off", v, Model.ELEMENTS, "metric").is_empty())
	_check("styles: hidden elements stay hidden", Model.items("betaflight", v, ["timer"], "metric").size() == 1)


func _severity() -> void:
	var low := Model.items("betaflight", Model.values(_telemetry(), _battery(20.0, 3.45)), ["battery_pct", "voltage"], "metric")
	_check("severity: low battery is a warning", low.all(func(i: Dictionary) -> bool: return i.severity == Model.WARNING))
	var empty := Model.items("betaflight", Model.values(_telemetry(), _battery(5.0, 3.2)), ["battery_pct", "voltage"], "metric")
	_check("severity: an empty battery is critical", empty.all(func(i: Dictionary) -> bool: return i.severity == Model.CRITICAL))
	var alarms: Array[String] = ["cell_warning", "cell_critical"]
	var warned := Model.items("betaflight", Model.values(_telemetry(), _battery(50.0, 3.4, alarms)), ["warnings"], "metric")
	_check("severity: the most urgent alarm wins the warning slot", warned.size() == 1 and warned[0].text == "LAND NOW" and warned[0].severity == Model.CRITICAL)
	_check("severity: no alarm, no warning", Model.items("betaflight", Model.values(_telemetry(), _battery()), ["warnings"], "metric").is_empty())


func _horizon() -> void:
	var level := Model.horizon(0.0, 0.0, 10.0, 0.0)
	_check("horizon: level flight through the centre", (level.offset as Vector2).is_zero_approx() and (level.along as Vector2).is_equal_approx(Vector2.RIGHT))
	_check("horizon: pitch up moves it down", (Model.horizon(5.0, 0.0, 10.0, 0.0).offset as Vector2).is_equal_approx(Vector2(0, 50)))
	_check("horizon: the uptilt puts it below the centre", (Model.horizon(0.0, 0.0, 10.0, 5.0).offset as Vector2).is_equal_approx(Vector2(0, 50)))
	var banked: Vector2 = Model.horizon(0.0, 30.0, 10.0, 0.0).along
	_check("horizon: right bank raises its right end", banked.y < 0.0 and is_equal_approx(rad_to_deg(atan2(-banked.y, banked.x)), 30.0), str(banked))


func _settings() -> void:
	_check("settings: defaults validate", CameraSettings.errors({}).is_empty())
	var normal := CameraSettings.normalized({})
	_check("settings: Betaflight style with the spec's elements by default", normal.camera_fpv_osd == "betaflight"
		and "horizon" in normal.camera_fpv_osd_elements and "home" in normal.camera_fpv_osd_elements and "link" in normal.camera_fpv_osd_elements)
	for bad: Dictionary in [{camera_fpv_osd = "dji"}, {camera_fpv_osd_elements = ["horizon", "radar"]}, {camera_fpv_osd_elements = "horizon"}]:
		_check("settings: refuses %s" % str(bad), not CameraSettings.errors(bad).is_empty())
	_check("settings: a file's PackedStringArray is accepted", CameraSettings.errors({camera_fpv_osd_elements = PackedStringArray(["timer"])}).is_empty()
		and CameraSettings.normalized({camera_fpv_osd_elements = PackedStringArray(["timer", "horizon"])}).camera_fpv_osd_elements == ["horizon", "timer"])
	var cam := PilotCamera.create(get_root(), { north = 0.0, east = 0.0, down = 0.0, eye_height = 1.7 })
	var rig := CameraRig.new(cam, 1.5)
	CameraSettings.apply_at_start(rig, {camera_fpv_osd = "ardupilot", camera_fpv_osd_elements = ["timer", "home"]})
	_check("settings: reach the rig", rig.onboard_osd.style == "ardupilot" and rig.onboard_osd.elements == ["timer", "home"])
	cam.free()


func _layer() -> void:
	var osd := FpvOsd.new()
	get_root().add_child(osd)
	osd.configure("inav", Model.DEFAULT_ELEMENTS, "metric")
	_check("layer: above the lens picture", osd.layer > -100)
	osd.feed({telemetry = _telemetry(), battery = {ok = true, time_s = 1.0, bus_voltage_v = 16.0, pack_current_a = 10.0}}, 120.0)
	_check("layer: feed builds the items", not osd.items.is_empty() and str(osd.evidence().items).contains("altitude:50.0M"), str(osd.evidence().items))
	osd.set_attitude(3.0, 10.0, 12.0, 5.0, 1.0)
	osd.visible = true
	await process_frame
	osd.reset()
	_check("layer: reset clears the numbers", osd.values.is_empty() and osd.items.is_empty())
	osd.configure("off", Model.DEFAULT_ELEMENTS, "metric")
	_check("layer: off disables it", not osd.enabled())
	osd.queue_free()
