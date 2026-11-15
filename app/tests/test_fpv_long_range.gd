# FC-3 (14a): long-range FPV gear and OSD figures. The 1.6 W and 2.5 W video transmitters and the patch / helical
# receiving antennas (render/camera/video_link.gd), and the trip, efficiency and remaining-time/distance OSD elements
# (render/overlays/fpv_osd_model.gd, fpv_osd.gd), all from existing telemetry and battery sensor figures.
# Run: godot --headless --path . --script res://tests/test_fpv_long_range.gd
extends SceneTree

const VideoLink := preload("res://render/camera/video_link.gd")
const Model := preload("res://render/overlays/fpv_osd_model.gd")
const FpvOsd := preload("res://render/overlays/fpv_osd.gd")
const CameraSettings := preload("res://render/camera/camera_settings.gd")
const DisplayPreferences := preload("res://app_state/display_preferences.gd")

var _failures := 0
var _count := 0


func _check(label: String, ok: bool, detail := "") -> void:
	_count += 1
	print(("ok   " if ok else "FAIL ") + label + ("" if ok or detail.is_empty() else "  " + detail))
	if not ok:
		_failures += 1


func _initialize() -> void:
	_video()
	_osd_values()
	_osd_feed()
	_settings()
	print("%d checks, %d failures" % [_count, _failures])
	quit(1 if _failures > 0 else 0)


## The distance at which the picture is half broken (margin 0) for a power and antenna.
func _half(power: float, antenna: String) -> float:
	return VideoLink.half_range_m(power) * pow(10.0, float(VideoLink.ANTENNA_GAIN_DB[antenna]) / 20.0)


func _video() -> void:
	_check("1.6 W and 2.5 W transmitters are offered", 1600 in VideoLink.POWERS_MW and 2500 in VideoLink.POWERS_MW)
	_check("2.5 W reaches 6 km with the stock antenna", is_equal_approx(VideoLink.half_range_m(2500.0), 6000.0))
	_check("the patch adds 8 dB (about 15 km at 2.5 W)", absf(_half(2500.0, "patch") - 15071.0) < 10.0, str(_half(2500.0, "patch")))
	_check("the helical adds 13 dB (about 27 km at 2.5 W)", absf(_half(2500.0, "helical") - 26799.0) < 10.0, str(_half(2500.0, "helical")))
	_check("the margin law takes the antenna gain", absf(VideoLink.margin_db(15071.0, 2500.0, false, 0.0, NAN,
		VideoLink.ANTENNA_GAIN_DB.patch)) < 0.01)
	var link := VideoLink.new()
	link.configure("analog", 2500, "helical")
	link.update(20000.0, false, 0.0, NAN, 0.0)
	var stock := VideoLink.new()
	stock.configure("analog", 2500, "omni")
	stock.update(20000.0, false, 0.0, NAN, 0.0)
	_check("at 20 km: helical still flies, the stock antenna is lost", link.quality > 0.75 and stock.quality < 0.01,
		"%.2f / %.2f" % [link.quality, stock.quality])
	link.configure("analog", 2500, "dish")
	_check("an unknown antenna is ignored", link.antenna == "helical")


func _battery(used: float) -> Dictionary:
	return {valid = true, pack_voltage_v = 16.0, cell_avg_v = 4.0, remaining_pct = 50.0, current_a = 10.0,
		used_mah = int(used), used_mah_raw = used, capacity_mah = 5000.0, alarms = []}


func _osd_values() -> void:
	# 600 s flown, 12 km trip, 2000 mAh used of 5000: 166.7 mAh/km; usable to the 20 % reserve 2000 mAh
	# → 600 s at the 3.33 mAh/s average, 12 km at the efficiency.
	var t := {ground_speed = 20.0, vertical_speed = 0.0, heading_deg = 0.0, pilot_north_m = 0.0, pilot_east_m = 0.0,
		time_s = 600.0, trip_m = 12000.0}
	var v := Model.values(t, _battery(2000.0))
	_check("efficiency: used mAh per km of trip", absf(float(v.efficiency_mah_km) - 166.67) < 0.01, str(v.efficiency_mah_km))
	_check("remaining time to the 20 % reserve at the average draw", absf(float(v.remaining_s) - 600.0) < 0.01, str(v.remaining_s))
	_check("remaining distance at this efficiency", absf(float(v.remaining_m) - 12000.0) < 0.1, str(v.remaining_m))
	var elements := ["trip", "efficiency", "remaining"]
	var inav := _texts(Model.items("inav", v, elements, "metric"))
	_check("INAV: TRIP 12.00KM, 167MAH/KM, REM 10:00 12.00KM", inav.get("trip", "") == "TRIP 12.00KM" and inav.get("efficiency", "") == "167MAH/KM"
		and inav.get("remaining", "") == "REM 10:00 12.00KM", str(inav))
	var imperial := _texts(Model.items("ardupilot", v, elements, "imperial"))
	_check("imperial efficiency per mile", imperial.get("efficiency", "") == "268MAH/MI", str(imperial))
	t.trip_m = 100.0
	_check("no efficiency before 200 m of trip", is_nan(float(Model.values(t, _battery(2000.0)).efficiency_mah_km)))
	t.time_s = 10.0
	_check("no remaining estimate in the first 30 s", is_nan(float(Model.values(t, _battery(20.0)).remaining_s)))
	t.time_s = 600.0
	t.trip_m = 12000.0
	var low := Model.values(t, _battery(3950.0))
	_check("under a minute left is a warning", Model.items("inav", low, ["remaining"], "metric")[0].severity == Model.WARNING,
		str(low.remaining_s))
	_check("glow and gas engines: no battery, no efficiency or remaining", _texts(Model.items("inav", Model.values(t, {}),
		elements, "metric")).keys() == ["trip"])
	for style: String in ["betaflight", "inav", "ardupilot"]:
		var cells: Dictionary = Model.LAYOUTS[style].cells
		var used := {}
		var clash := false
		for id: String in cells:
			var key := "%d,%d" % [cells[id][0], cells[id][1]]
			clash = clash or used.has(key)
			used[key] = true
		_check("%s: every element has its own OSD cell, the new ones included" % style, not clash
			and cells.has("trip") and cells.has("efficiency") and cells.has("remaining"))


func _texts(items: Array) -> Dictionary:
	var out := {}
	for item: Dictionary in items:
		out[item.id] = item.text
	return out


func _osd_feed() -> void:
	var osd := FpvOsd.new()
	osd.configure("inav", Model.DEFAULT_ELEMENTS, "metric")
	for i in 101: # 10 s at the 0.1 s OSD rate, 25 m/s
		osd.feed({telemetry = {ground_speed = 25.0, vertical_speed = 0.0, heading_deg = 0.0, pilot_north_m = 0.0,
			pilot_east_m = 0.0, time_s = i * 0.1}}, 0.0)
	_check("the trip integrates GPS ground speed (10 s at 25 m/s = 250 m)", absf(osd.trip_m - 250.0) < 0.01, str(osd.trip_m))
	osd.feed({telemetry = {ground_speed = 25.0, time_s = 60.0, heading_deg = 0.0, pilot_north_m = 0.0, pilot_east_m = 0.0}}, 0.0)
	_check("a gap (pause, menu) is not bridged", absf(osd.trip_m - 250.0) < 0.01, str(osd.trip_m))
	osd.reset()
	_check("a new flight starts the trip at zero", osd.trip_m == 0.0)
	_check("trip and remaining are shown by default", "trip" in Model.DEFAULT_ELEMENTS and "remaining" in Model.DEFAULT_ELEMENTS)
	osd.free()


func _settings() -> void:
	_check("the receiving antenna defaults to stock", CameraSettings.DEFAULTS.camera_fpv_rx_antenna == "omni")
	var bad := CameraSettings.DEFAULTS.duplicate()
	bad.camera_fpv_rx_antenna = "dish"
	_check("unknown antennas are rejected", CameraSettings.errors(bad).size() == 1, str(CameraSettings.errors(bad)))
	bad = CameraSettings.DEFAULTS.duplicate()
	bad.camera_fpv_vtx_power = 2500
	_check("2500 mW is a valid transmitter power", CameraSettings.errors(bad).is_empty())
	_check("saved as fpv_rx_antenna", DisplayPreferences.CAMERA_FILE_KEYS.get("camera_fpv_rx_antenna") == "fpv_rx_antenna")
