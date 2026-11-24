extends RefCounted
## Telemetry for an EdgeTX radio connected over USB serial (input/serial_radio_link.gd, radio side
## tools/radio/edgetx/SCRIPTS/TELEMETRY/simlnk.lua). The flight publishes what its overlays already show
## (render/overlays/fpv_osd_model.gd values plus attitude, arming and throttle) about 10 times a second; the link turns
## the latest reading into the line protocol below. Nothing is invented: a figure the flight does not have is sent as
## an empty field, and there is no RSSI or link quality (the simulator has no radio link).
##
##   B,<volts>,<amps>,<mAh used>,<% left>*cs
##   A,<alt m>,<vspeed m/s>,<ground km/h>,<air km/h>,<heading deg>,<pitch deg>,<roll deg>*cs
##   N,<home distance m>,<bearing to home deg>,<lat deg>,<lon deg>*cs
##   M,<mode>,<armed 0/1>,<flight time s>,<throttle %>*cs
##   I,<simulator>,<aircraft>*cs
## cs: two hex digits, the sum of the payload bytes modulo 256.

## Pilot spots of the geo-referenced landscapes in D96/TM (EPSG:3794), metres: the landscape's core origin plus its
## PILOT_CORE (landscapes/*/landscape.gd; test_radio_telemetry.gd keeps them equal). Fictional fields have no GPS.
const PILOT_D96 := {
	"kamnik_duplica": Vector2(467840.0, 117512.0),
	"triglav_tamar": Vector2(401524.0, 151124.0),
}
const STALE_MS := 1000

## The flight's latest reading ({} = none) and when it was published (Time.get_ticks_msec()).
## True while a radio is connected over USB serial (set by input/serial_radio_link.gd), so flights only build
## telemetry when someone receives it.
static var listening := false
static var _latest: Dictionary = {}
static var _latest_ms := -1000000


static func publish(values: Dictionary, now_ms := -1) -> void:
	_latest = values
	_latest_ms = Time.get_ticks_msec() if now_ms < 0 else now_ms


static func clear() -> void:
	_latest = {}
	_latest_ms = -1000000


## The latest reading, or {} once it is older than STALE_MS (no flight, a menu, a paused or ended flight).
static func current(now_ms: int) -> Dictionary:
	return _latest if now_ms - _latest_ms < STALE_MS else {}


## One flight reading. osd: FpvOsdModel.values(); t: the telemetry snapshot (render/overlays/telemetry.gd); armed and
## throttle (0..1) from the session's radio and simulation; landscape: Landscapes id; aircraft: display name.
static func reading(osd: Dictionary, t: Dictionary, armed: bool, throttle: float, landscape: String, aircraft: String) -> Dictionary:
	var heading := float(osd.get("heading_deg", NAN))
	var relative := float(osd.get("home_relative_deg", NAN))
	var position := geo_position(landscape, float(t.get("pilot_east_m", NAN)), float(t.get("pilot_north_m", NAN)))
	return {
		volt = float(osd.get("voltage_v", NAN)), curr = float(osd.get("current_a", NAN)),
		mah = float(osd.get("used_mah", NAN)), pct = float(osd.get("remaining_pct", NAN)),
		alt = float(osd.get("altitude_m", NAN)), vs = float(t.get("vertical_speed", NAN)),
		gs = float(t.get("ground_speed", NAN)) * 3.6, aspd = float(osd.get("airspeed_mps", NAN)) * 3.6,
		hdg = heading, pitch = float(t.get("pitch_deg", NAN)), roll = float(t.get("bank_deg", NAN)),
		dist = float(osd.get("home_distance_m", NAN)),
		home_dir = fposmod(heading + relative, 360.0) if is_finite(heading) and is_finite(relative) else NAN,
		lat = position[0], lon = position[1],
		mode = mode_text(str(osd.get("flight_mode", "manual"))), armed = armed,
		time = float(osd.get("time_s", NAN)), thr = clampf(throttle, 0.0, 1.0) * 100.0 if is_finite(throttle) else NAN,
		aircraft = aircraft,
	}


## The flight-controller mode as the short text iNav sends over CRSF (what EdgeTX scripts expect in FM).
static func mode_text(mode: String) -> String:
	var known := {manual = "MANU", acro = "ACRO", angle = "ANGL", horizon = "HOR", rth = "RTH", cruise = "CRUZ",
		loiter = "LOTR", poshold = "HOLD", althold = "AH", waypoint = "WP", land = "LAND", launch = "LNCH",
		failsafe = "!FS!", stabilized = "ANGL"}
	var key := mode.to_lower()
	if known.has(key):
		return known[key]
	return key.to_upper().replace(",", " ").substr(0, 4) if not key.is_empty() else "MANU"


## The lines for one 10 Hz send: attitude and mode every time, battery and navigation every second time, the
## identity line every fifth (so the radio sees the simulator even without a flight).
static func lines(values: Dictionary, tick: int, simulator := "OpenRC") -> PackedStringArray:
	var out := PackedStringArray()
	if tick % 5 == 0:
		out.append(line(["I", simulator, str(values.get("aircraft", ""))]))
	if values.is_empty():
		return out
	out.append(line(["A", num(values, "alt", 1), num(values, "vs", 1), num(values, "gs", 1), num(values, "aspd", 1),
		num(values, "hdg", 0), num(values, "pitch", 1), num(values, "roll", 1)]))
	out.append(line(["M", str(values.get("mode", "")), "1" if bool(values.get("armed", false)) else "0",
		num(values, "time", 0), num(values, "thr", 0)]))
	if tick % 2 == 0:
		out.append(line(["B", num(values, "volt", 2), num(values, "curr", 1), num(values, "mah", 0), num(values, "pct", 0)]))
		out.append(line(["N", num(values, "dist", 0), num(values, "home_dir", 0), num(values, "lat", 6), num(values, "lon", 6)]))
	return out


## A field with `decimals` decimals, or "" when the value is missing or not finite.
static func num(values: Dictionary, key: String, decimals: int) -> String:
	var v: Variant = values.get(key, NAN)
	if typeof(v) not in [TYPE_FLOAT, TYPE_INT] or not is_finite(float(v)):
		return ""
	if decimals == 0:
		return str(roundi(float(v)))
	return ("%." + str(decimals) + "f") % float(v)


## Joins the fields with commas (commas inside text become spaces) and appends "*" + checksum and a newline.
static func line(fields: Array) -> String:
	var parts := PackedStringArray()
	for field in fields:
		parts.append(str(field).replace(",", " ").replace("*", " ").replace("\n", " "))
	var payload := ",".join(parts)
	return "%s*%02X\n" % [payload, checksum(payload)]


static func checksum(payload: String) -> int:
	var sum := 0
	for b in payload.to_utf8_buffer():
		sum += b
	return sum % 256


## [latitude, longitude] (degrees, WGS84 ~ ETRS89, 64-bit) of a point `east_m`/`north_m` from the pilot (grid axes),
## or [NAN, NAN] on a landscape without a geo-reference.
static func geo_position(landscape: String, east_m: float, north_m: float) -> PackedFloat64Array:
	if not PILOT_D96.has(landscape) or not is_finite(east_m) or not is_finite(north_m):
		return PackedFloat64Array([NAN, NAN])
	var pilot: Vector2 = PILOT_D96[landscape]
	return d96_to_wgs84(pilot.x + east_m, pilot.y + north_m)


## D96/TM (GRS80 transverse Mercator, central meridian 15 E, k0 0.9999, false easting 500 km, false northing
## -5000 km) to latitude/longitude in degrees. Port of research/triglav/d96.py (Snyder 1987, eqs. 8-12 to 8-25).
static func d96_to_wgs84(east: float, north: float) -> PackedFloat64Array:
	const A := 6378137.0
	const F := 1.0 / 298.257222101
	const K0 := 0.9999
	var e2 := F * (2.0 - F)
	var ep2 := e2 / (1.0 - e2)
	var x := (east - 500000.0) / K0
	var m := (north + 5000000.0) / K0
	var mu := m / (A * (1.0 - e2 / 4.0 - 3.0 * e2 * e2 / 64.0 - 5.0 * e2 * e2 * e2 / 256.0))
	var e1 := (1.0 - sqrt(1.0 - e2)) / (1.0 + sqrt(1.0 - e2))
	var phi1 := mu + (3.0 * e1 / 2.0 - 27.0 * pow(e1, 3) / 32.0) * sin(2.0 * mu) \
		+ (21.0 * e1 * e1 / 16.0 - 55.0 * pow(e1, 4) / 32.0) * sin(4.0 * mu) \
		+ (151.0 * pow(e1, 3) / 96.0) * sin(6.0 * mu) + (1097.0 * pow(e1, 4) / 512.0) * sin(8.0 * mu)
	var c1 := ep2 * cos(phi1) * cos(phi1)
	var t1 := tan(phi1) * tan(phi1)
	var n1 := A / sqrt(1.0 - e2 * sin(phi1) * sin(phi1))
	var r1 := A * (1.0 - e2) / pow(1.0 - e2 * sin(phi1) * sin(phi1), 1.5)
	var d := x / n1
	var lat := phi1 - (n1 * tan(phi1) / r1) * (d * d / 2.0 - (5.0 + 3.0 * t1 + 10.0 * c1 - 4.0 * c1 * c1 - 9.0 * ep2) * pow(d, 4) / 24.0
		+ (61.0 + 90.0 * t1 + 298.0 * c1 + 45.0 * t1 * t1 - 252.0 * ep2 - 3.0 * c1 * c1) * pow(d, 6) / 720.0)
	var lon := deg_to_rad(15.0) + (d - (1.0 + 2.0 * t1 + c1) * pow(d, 3) / 6.0
		+ (5.0 - 2.0 * c1 + 28.0 * t1 - 3.0 * c1 * c1 + 8.0 * ep2 + 24.0 * t1 * t1) * pow(d, 5) / 120.0) / cos(phi1)
	return PackedFloat64Array([rad_to_deg(lat), rad_to_deg(lon)])
