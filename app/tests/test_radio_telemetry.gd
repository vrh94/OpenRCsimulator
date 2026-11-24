# Telemetry for an EdgeTX radio over USB serial (sim/radio_telemetry.gd): field mapping from the OSD values, empty
# fields for missing figures, the line format and checksum shared with simlnk.lua, staleness, and GPS positions on
# the geo-referenced landscapes (D96/TM -> WGS84, checked against research/triglav/d96.py).
# Run: python3 tools/godot/run_checked.py --timeout 60 -- "$(app/get-godot.sh)" --headless --path app --script res://tests/test_radio_telemetry.gd
extends SceneTree

const RadioTelemetry := preload("res://sim/radio_telemetry.gd")
const Kamnik := preload("res://landscapes/kamnik_duplica/landscape.gd")
const Triglav := preload("res://landscapes/triglav_tamar/landscape.gd")
const TriglavHeightfield := preload("res://landscapes/triglav_tamar/heightfield.gd")

var _failures := 0


func _check(label: String, ok: bool, detail := "") -> void:
	if ok:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL %s %s" % [label, detail])


func _initialize() -> void:
	_geo()
	_reading()
	_lines()
	_staleness()
	print("all radio telemetry checks passed" if _failures == 0 else "%d radio telemetry check(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)


func _geo() -> void:
	_check("geo: Kamnik's pilot spot matches the landscape's core origin + PILOT_CORE",
		RadioTelemetry.PILOT_D96.kamnik_duplica == Kamnik.CORE_ORIGIN + Kamnik.PILOT_CORE)
	_check("geo: Triglav's pilot spot matches the landscape's core origin + PILOT_CORE",
		RadioTelemetry.PILOT_D96.triglav_tamar == Vector2(TriglavHeightfield.CORE_ORIGIN_EAST_M, TriglavHeightfield.CORE_ORIGIN_NORTH_M) + Triglav.PILOT_CORE)
	# Reference values from research/triglav/d96.py (numpy, float64).
	for case: Array in [["kamnik_duplica", 0.0, 0.0, 46.1966067, 14.5833157], ["triglav_tamar", 0.0, 0.0, 46.4925822, 13.7171763],
			["kamnik_duplica", 1000.0, 1000.0, 46.2056503, 14.5962061]]:
		var p := RadioTelemetry.geo_position(case[0], case[1], case[2])
		_check("geo: %s +%d m E/N -> %.7f, %.7f" % [case[0], case[1], case[3], case[4]],
			absf(p[0] - case[3]) < 2e-7 and absf(p[1] - case[4]) < 2e-7, "%.8f %.8f" % [p[0], p[1]])
	var none := RadioTelemetry.geo_position("airfield", 0.0, 0.0)
	_check("geo: a fictional field has no position", is_nan(none[0]) and is_nan(none[1]))


func _reading() -> void:
	var osd := {heading_deg = 350.0, home_relative_deg = 30.0, voltage_v = 16.4, current_a = 12.5, used_mah = 734.0,
		remaining_pct = 62.0, altitude_m = 120.0, airspeed_mps = 20.0, home_distance_m = 612.0, time_s = 93.4,
		flight_mode = "angle"}
	var t := {vertical_speed = 1.5, ground_speed = 15.0, pitch_deg = 3.0, bank_deg = -10.0, pilot_east_m = 1000.0, pilot_north_m = 1000.0}
	var v := RadioTelemetry.reading(osd, t, true, 0.48, "kamnik_duplica", "Ugly Stik")
	_check("reading: speeds in km/h", is_equal_approx(v.gs, 54.0) and is_equal_approx(v.aspd, 72.0))
	_check("reading: bearing to home = heading + relative, wrapped", is_equal_approx(v.home_dir, 20.0), str(v.home_dir))
	_check("reading: mode as iNav's CRSF text, armed, throttle %", v.mode == "ANGL" and v.armed and is_equal_approx(v.thr, 48.0))
	_check("reading: position on Kamnik", absf(v.lat - 46.2056503) < 2e-7 and absf(v.lon - 14.5962061) < 2e-7)
	var bare := RadioTelemetry.reading({}, {}, false, NAN, "airfield", "")
	var text := "".join(RadioTelemetry.lines(bare, 0))
	_check("reading: an aircraft without battery or GPS sends empty fields, never zeros",
		text.contains("B,,,,*") and text.contains("N,,,,*") and text.contains("A,,,,,,,*") and text.contains("M,MANU,0,,*"), text)
	_check("mode text: known and unknown modes", RadioTelemetry.mode_text("rth") == "RTH" and RadioTelemetry.mode_text("Turtle") == "TURT"
		and RadioTelemetry.mode_text("") == "MANU")


func _lines() -> void:
	# The checksum is the byte sum modulo 256, as in simlnk.lua; this value was computed independently.
	_check("line: format and checksum", RadioTelemetry.line(["B", "16.40", "12.5", "734", "62"]) == "B,16.40,12.5,734,62*B7\n",
		RadioTelemetry.line(["B", "16.40", "12.5", "734", "62"]))
	_check("line: commas, stars and newlines inside text cannot break a line",
		RadioTelemetry.line(["I", "OpenRC", "Stik, *60*\n"]).begins_with("I,OpenRC,Stik   60  *"))
	var values := {alt = 1.0, mode = "ACRO", armed = false}
	var counts: Array = []
	for tick in 10:
		counts.append(RadioTelemetry.lines(values, tick).size())
	_check("line: cadence (I every 5th, B and N every 2nd, A and M always)", counts == [5, 2, 4, 2, 4, 3, 4, 2, 4, 2], str(counts))
	_check("line: without a flight only the identity line is sent, every 5th time",
		RadioTelemetry.lines({}, 0).size() == 1 and RadioTelemetry.lines({}, 1).is_empty())
	_check("num: NAN and missing are empty, integers round", RadioTelemetry.num({a = NAN}, "a", 1) == ""
		and RadioTelemetry.num({}, "a", 0) == "" and RadioTelemetry.num({a = 2.5}, "a", 0) == "3" and RadioTelemetry.num({a = -1.26}, "a", 1) == "-1.3")


func _staleness() -> void:
	RadioTelemetry.publish({alt = 5.0}, 1000)
	_check("current: fresh within a second", RadioTelemetry.current(1999).get("alt", 0.0) == 5.0)
	_check("current: stale after a second (menus, ended flights)", RadioTelemetry.current(2000).is_empty())
	RadioTelemetry.clear()
	_check("clear: nothing published", RadioTelemetry.current(0).is_empty())
