## FPV-6: the fixed-wing FPV OSD model. Pure, presentation-side: it formats the session's existing telemetry
## (render/overlays/telemetry.gd via OverlayManager.snapshot) and the battery sensors' reading
## (render/overlays/battery_sensors.gd) into the text items of a flight-controller character OSD, laid out in one of
## three styles that follow the look of Betaflight, INAV and ArduPilot (their element choices, labels and usual
## places; the drawing and the glyphs are this project's own). Nothing is invented: an element whose source is
## absent is not shown (no battery on a glow or gas engine, no link quality until a video link is modelled).
## Home is the pilot station (the telemetry's pilot vector); altitude is height above it, speed the 3D GPS speed
## (ground speed and climb rate together, as INAV's 3D speed: it rises in a dive, where the horizontal ground speed
## alone falls), the timer the flight time. The grid is COLS × ROWS character cells over a 16:9 safe area, as on an
## HD goggle OSD.
extends RefCounted

const OsdModel = preload("res://vehicles/multirotor/osd_model.gd")
const FixedWingFC = preload("res://sim/fixed_wing_fc.gd")

const STYLES: Array[String] = ["off", "betaflight", "inav", "ardupilot"]
const DEFAULT_STYLE := "betaflight"
const ELEMENTS: Array[String] = ["horizon", "crosshair", "voltage", "battery_pct", "current", "timer", "speed",
	"altitude", "home", "link", "heading", "airspeed", "mode", "warnings"]
const ELEMENT_NAMES := {"horizon": "Artificial horizon", "crosshair": "Crosshair", "voltage": "Battery voltage",
	"battery_pct": "Battery %", "current": "Current and mAh", "timer": "Flight timer", "speed": "GPS speed",
	"altitude": "Altitude", "home": "Home arrow and distance", "link": "Signal strength", "heading": "Heading",
	"airspeed": "Airspeed", "mode": "Flight mode", "warnings": "Warnings"}
const DEFAULT_ELEMENTS: Array[String] = ["horizon", "crosshair", "voltage", "battery_pct", "current", "timer", "speed",
	"altitude", "home", "link", "heading", "mode", "warnings"]
const UNITS: Array[String] = ["metric", "imperial"]
const COLS := 50
const ROWS := 18
## Severities (painter colours on HD; analog stays white): normal, info, warning, critical.
const NORMAL := 0
const INFO := 1
const WARNING := 2
const CRITICAL := 3
## Battery bands (remaining %, average cell V) and link bands (%).
const PCT_WARNING := 25.0
const PCT_CRITICAL := 10.0
const CELL_WARNING_V := 3.5
const CELL_CRITICAL_V := 3.3
const LINK_WARNING := 30.0
const LINK_CRITICAL := 10.0
## Numbers refresh at a flight controller's OSD rate; the horizon follows every frame.
const REFRESH_S := 0.1

## Per style: each element's cell (column, row) and alignment (-1 left from the cell, 0 centred, 1 right ending at
## it); the horizon and crosshair sit at the picture centre. The crosshair glyph and the horizon dressing differ.
const LAYOUTS := {
	"betaflight": {
		crosshair = "default", ladder = false, sidebars = true,
		cells = {link = [1, 1, -1], home = [25, 1, 0], heading = [25, 2, 0], speed = [1, 9, -1], altitude = [48, 9, 1],
			airspeed = [1, 10, -1], mode = [48, 1, 1], current = [1, 15, -1], voltage = [1, 16, -1],
			battery_pct = [11, 16, -1], timer = [48, 16, 1], warnings = [25, 12, 0]},
	},
	"inav": {
		crosshair = "aircraft", ladder = true, sidebars = true,
		cells = {link = [1, 1, -1], heading = [25, 1, 0], home = [25, 2, 0], mode = [48, 1, 1], speed = [1, 8, -1],
			airspeed = [1, 9, -1], altitude = [48, 8, 1], current = [1, 15, -1], voltage = [1, 16, -1],
			battery_pct = [12, 16, -1], timer = [48, 16, 1], warnings = [25, 13, 0]},
	},
	"ardupilot": {
		crosshair = "cross", ladder = false, sidebars = false,
		cells = {voltage = [1, 1, -1], battery_pct = [12, 1, -1], current = [1, 2, -1], mode = [25, 1, 0],
			home = [25, 2, 0], link = [48, 1, 1], altitude = [48, 8, 1], speed = [1, 16, -1], airspeed = [1, 15, -1],
			heading = [25, 16, 0], timer = [48, 16, 1], warnings = [25, 13, 0]},
	},
}


## The OSD's input from one telemetry snapshot. t: Telemetry.compute(); battery: a BatterySensors reading (or {});
## link: {quality_pct} from a video-link model, or {} (no link figure is shown). FC-1: t.flight_mode is the flight
## controller's mode (sim/fixed_wing_fc.gd MODES; "manual" when absent).
static func values(t: Dictionary, battery: Dictionary, link: Dictionary = {}) -> Dictionary:
	var north := float(t.get("pilot_north_m", NAN))
	var east := float(t.get("pilot_east_m", NAN))
	var heading := float(t.get("heading_deg", NAN))
	var home := {distance_m = NAN, relative_deg = NAN}
	if is_finite(north) and is_finite(east) and is_finite(heading):
		home = OsdModel.home_vector(north, east, heading, Vector2.ZERO)
	var has_battery := bool(battery.get("valid", false))
	return {
		speed_mps = _speed_3d(t),
		airspeed_mps = float(t.get("airspeed", NAN)),
		altitude_m = _height_above_home(t),
		heading_deg = heading,
		home_distance_m = float(home.distance_m),
		home_relative_deg = float(home.relative_deg),
		time_s = float(t.get("time_s", NAN)),
		voltage_v = float(battery.get("pack_voltage_v", NAN)) if has_battery else NAN,
		cell_v = float(battery.get("cell_avg_v", NAN)) if has_battery else NAN,
		remaining_pct = float(battery.get("remaining_pct", NAN)) if has_battery else NAN,
		current_a = float(battery.get("current_a", NAN)) if has_battery else NAN,
		used_mah = float(battery.get("used_mah", NAN)) if has_battery else NAN,
		link_pct = float(link.get("quality_pct", NAN)),
		warning = _warning(battery if has_battery else {}),
		flight_mode = str(t.get("flight_mode", "manual")),
	}


## The text items of one OSD frame: [{id, cell: Vector2i, align, text, severity, icon}]. icon: "" or "battery",
## "clock", "arrow", "antenna", "home"; value is the icon's figure (state of charge 0…1, arrow angle).
static func items(style: String, v: Dictionary, elements: Array, units: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var layout: Dictionary = LAYOUTS.get(style, {})
	if layout.is_empty():
		return out
	var cells: Dictionary = layout.cells
	for id: String in ELEMENTS:
		if id not in elements or not cells.has(id):
			continue
		var item := _item(style, id, v, units)
		if item.is_empty():
			continue
		var cell: Array = cells[id]
		item.id = id
		item.cell = Vector2i(int(cell[0]), int(cell[1]))
		item.align = int(cell[2])
		out.append(item)
	return out


static func _item(style: String, id: String, v: Dictionary, units: String) -> Dictionary:
	match id:
		"voltage":
			var volts := float(v.voltage_v)
			if not is_finite(volts):
				return {}
			var text := "%.1fV" % volts
			if style == "inav" and is_finite(float(v.cell_v)):
				text += " %.2fV" % float(v.cell_v)
			elif style == "ardupilot":
				text = "BAT " + text
			return _with(text, _cell_severity(float(v.cell_v)), "battery" if style != "ardupilot" else "",
				float(v.remaining_pct) / 100.0)
		"battery_pct":
			var pct := float(v.remaining_pct)
			if not is_finite(pct):
				return {}
			return _with("%d%%" % roundi(pct), _pct_severity(pct))
		"current":
			var amps := float(v.current_a)
			if not is_finite(amps):
				return {}
			var used := float(v.used_mah)
			var mah := ("%dMAH" if style != "ardupilot" else "%dmAh") % roundi(used) if is_finite(used) else ""
			return _with(("%.1fA" % amps) + ("  " + mah if not mah.is_empty() else ""), NORMAL)
		"timer":
			var seconds := float(v.time_s)
			if not is_finite(seconds):
				return {}
			var clock := OsdModel.clock_text(seconds)
			return _with({betaflight = clock, inav = "FLY " + clock, ardupilot = "FLT " + clock}.get(style, clock), NORMAL,
				"clock" if style == "betaflight" else "")
		"speed":
			var mps := float(v.speed_mps)
			if not is_finite(mps):
				return {}
			var speed := _compact(OsdModel.speed_text(mps, units))
			return _with({betaflight = speed, inav = speed, ardupilot = "GS " + speed}.get(style, speed), NORMAL)
		"airspeed":
			var air := float(v.airspeed_mps)
			if not is_finite(air):
				return {}
			return _with(("AS " if style != "ardupilot" else "AS ") + _compact(OsdModel.speed_text(air, units)), NORMAL)
		"altitude":
			var m := float(v.altitude_m)
			if not is_finite(m):
				return {}
			var alt := _compact(OsdModel.altitude_text(m, units))
			return _with({betaflight = "ALT " + alt, inav = alt, ardupilot = "ALT " + alt}.get(style, alt), NORMAL)
		"home":
			var d := float(v.home_distance_m)
			if not is_finite(d):
				return {}
			var item := _with(_compact(OsdModel.distance_text(d, units)), NORMAL, "arrow", float(v.home_relative_deg))
			if style == "ardupilot":
				item.text = "H " + item.text
			return item
		"heading":
			var h := float(v.heading_deg)
			if not is_finite(h):
				return {}
			var deg := posmod(roundi(h), 360)
			return _with({betaflight = "%03d" % deg, inav = "%03d°" % deg, ardupilot = "HDG %03d" % deg}.get(style, str(deg)), NORMAL)
		"link":
			var q := float(v.link_pct)
			if not is_finite(q):
				return {}
			var pct := clampi(roundi(q), 0, 99)
			return _with({betaflight = "%d" % pct, inav = "LQ %d" % pct, ardupilot = "RSSI %d" % pct}.get(style, str(pct)),
				_link_severity(q), "antenna" if style == "betaflight" else "")
		"mode":
			# FC-1: the flight controller's mode as the firmware prints it (Betaflight shows nothing in manual).
			var mode := str(v.get("flight_mode", "manual"))
			return _with(FixedWingFC.osd_label(mode, style), WARNING if mode == "rth" else NORMAL)
		"warnings":
			var warning: Dictionary = v.get("warning", {})
			if str(warning.get("text", "")).is_empty():
				return {}
			return _with(str(warning.text), int(warning.get("severity", WARNING)))
	return {}


static func _with(text: String, severity: int, icon := "", value := 0.0) -> Dictionary:
	if text.is_empty():
		return {}
	return {text = text, severity = severity, icon = icon, value = value}


## OsdModel's unit texts without the space ("45 KM/H" → "45KM/H"), as on a character OSD.
static func _compact(text: String) -> String:
	return text.replace(" ", "")


## Height above the pilot station's ground: the telemetry's height above the datum less `home_up_m` (the station's
## ground height above the datum, which the route adds to the telemetry), as a GPS OSD shows height above home.
## 3D GPS speed (m/s) from the telemetry's horizontal ground speed and vertical speed; NAN without them.
static func _speed_3d(t: Dictionary) -> float:
	var horizontal := float(t.get("ground_speed", NAN))
	var vertical := float(t.get("vertical_speed", 0.0))
	if not is_finite(horizontal):
		return NAN
	return sqrt(horizontal * horizontal + (vertical * vertical if is_finite(vertical) else 0.0))


static func _height_above_home(t: Dictionary) -> float:
	var datum := float(t.get("height_datum", NAN))
	var home_up := float(t.get("home_up_m", NAN))
	return datum - home_up if is_finite(datum) and is_finite(home_up) else NAN


static func _pct_severity(pct: float) -> int:
	return CRITICAL if pct < PCT_CRITICAL else (WARNING if pct < PCT_WARNING else NORMAL)


static func _cell_severity(cell: float) -> int:
	if not is_finite(cell):
		return NORMAL
	return CRITICAL if cell < CELL_CRITICAL_V else (WARNING if cell < CELL_WARNING_V else NORMAL)


static func _link_severity(q: float) -> int:
	return CRITICAL if q < LINK_CRITICAL else (WARNING if q < LINK_WARNING else NORMAL)


## One warning slot from the battery sensors' alarms (most urgent first), like a flight controller's.
static func _warning(battery: Dictionary) -> Dictionary:
	var alarms: Array = battery.get("alarms", [])
	for alarm: String in ["exhausted", "cell_critical", "lvc", "cell_warning", "used_capacity", "hot"]:
		if alarm in alarms:
			return {
				exhausted = {text = "BATT EMPTY", severity = CRITICAL},
				cell_critical = {text = "LAND NOW", severity = CRITICAL},
				lvc = {text = "LOW VOLTAGE CUT", severity = CRITICAL},
				cell_warning = {text = "LOW BATTERY", severity = WARNING},
				used_capacity = {text = "BATT 80% USED", severity = WARNING},
				hot = {text = "BATT HOT", severity = WARNING},
			}[alarm]
	return {}


## The horizon line for attitude (deg) on a picture: its centre offset from the picture centre and its direction,
## in pixels. px_per_deg: the lens's scale at the centre; uptilt: the camera's uptilt (deg). Pitch up moves the
## horizon down; right bank turns it counter-clockwise on screen (INAV's camera-uptilt-corrected AHI).
static func horizon(pitch_deg: float, bank_deg: float, px_per_deg: float, uptilt_deg: float) -> Dictionary:
	var b := deg_to_rad(-bank_deg)
	var along := Vector2(cos(b), sin(b))
	var down := Vector2(-along.y, along.x)
	return {offset = down * (pitch_deg + uptilt_deg) * px_per_deg, along = along}


static func valid_elements(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY and typeof(value) != TYPE_PACKED_STRING_ARRAY:
		return false
	for e: Variant in value:
		if typeof(e) != TYPE_STRING or e not in ELEMENTS:
			return false
	return true
