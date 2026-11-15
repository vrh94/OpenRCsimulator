## FPV-6: the fixed-wing FPV OSD on screen, over the onboard picture (render/overlays/fpv_osd_model.gd formats it).
## The route feeds the telemetry snapshot at the OSD refresh rate (feed()) and the drawn attitude every frame
## (set_attitude()); the numbers refresh at 10 Hz like a flight controller's OSD, the horizon every frame. Its battery
## sensors sample in every view, so the used mAh stays right when the pilot switches to the onboard view.
## Presentation only.
extends CanvasLayer

const Model = preload("res://render/overlays/fpv_osd_model.gd")
const Painter = preload("res://vehicles/multirotor/osd_painter.gd")
const OsdModel = preload("res://vehicles/multirotor/osd_model.gd")
const BatterySensors = preload("res://render/overlays/battery_sensors.gd")

## Above the lens picture (FpvLens LAYER −100), below the route's panels and menus.
const LAYER := -90
## Safe area: the 16:9 rectangle inside the window, less this share at each edge (goggle OSD margins).
const MARGIN := 0.03
const AHI_HALF_SHARE := 0.17 # half the horizon line, share of the safe width
const AHI_GAP_SHARE := 0.035 # the gap around the crosshair
const AHI_MAX_OFFSET_SHARE := 0.32 # the horizon stays within this share of the safe height from the centre
const SIDEBAR_X_SHARE := 0.2
const SIDEBAR_HALF_SHARE := 0.13
const LADDER_RUNGS: Array[int] = [-20, -10, 10, 20]

var style := Model.DEFAULT_STYLE
var elements: Array = Model.DEFAULT_ELEMENTS.duplicate()
var units := "metric"
var sensors = BatterySensors.new()
## FC-2: the last battery sensor reading (the low-battery failsafe reads its alarms).
var last_reading := {}
var values := {}
var items: Array[Dictionary] = []
var _pitch := 0.0
var _bank := 0.0
var _px_per_deg := 10.0
var _uptilt := 0.0
var _clock := 0.0
var _canvas: Control


func _init() -> void:
	name = "FpvOsd"
	layer = LAYER
	visible = false
	_canvas = Control.new()
	_canvas.name = "OsdCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_draw_osd)
	add_child(_canvas)


func configure(style_id: String, element_ids: Array, unit_system: String) -> void:
	if style_id in Model.STYLES:
		style = style_id
	if Model.valid_elements(element_ids):
		elements = element_ids.duplicate()
	if unit_system in Model.UNITS:
		units = unit_system
	_rebuild()


func enabled() -> bool:
	return style != "off"


## One telemetry snapshot (OverlayManager.snapshot): numbers, battery sensors, warnings. home_up_m: the pilot
## station's ground height above the datum; link: {quality_pct} or {}.
## FC-1/2: flight_mode and fc ({failsafe, awaiting_pilot}) are the flight controller's state.
func feed(snapshot: Dictionary, home_up_m: float, link: Dictionary = {}, flight_mode := "manual", fc: Dictionary = {}) -> void:
	var t: Dictionary = snapshot.get("telemetry", {}).duplicate()
	if t.is_empty():
		return
	t.home_up_m = home_up_m
	t.flight_mode = flight_mode
	t.failsafe = str(fc.get("failsafe", ""))
	t.fc_awaiting_pilot = bool(fc.get("awaiting_pilot", false))
	var battery: Dictionary = snapshot.get("battery", {})
	var reading: Dictionary = {}
	if battery.get("ok", false):
		reading = sensors.update(float(battery.get("time_s", t.get("time_s", 0.0))), battery, false)
	last_reading = reading
	values = Model.values(t, reading, link)
	_rebuild()


## The drawn attitude (deg), the lens scale at the picture centre (px per degree), the camera uptilt (deg) and the
## presentation clock (s, for blinking warnings). Redraws.
func set_attitude(pitch_deg: float, bank_deg: float, px_per_deg: float, uptilt_deg: float, clock_s: float) -> void:
	_pitch = pitch_deg
	_bank = bank_deg
	_px_per_deg = px_per_deg
	_uptilt = uptilt_deg
	_clock = clock_s
	if visible:
		_canvas.queue_redraw()


## A new flight: fresh battery sensors and numbers.
func reset() -> void:
	sensors.reset()
	last_reading = {}
	values = {}
	items.clear()


func evidence() -> Dictionary:
	return {style = style, elements = elements, units = units, items = items.map(func(i: Dictionary) -> String: return "%s:%s" % [i.id, i.text])}


func _rebuild() -> void:
	items = Model.items(style, values, elements, units) if not values.is_empty() else ([] as Array[Dictionary])
	if visible:
		_canvas.queue_redraw()


## The safe area (px) and one character cell (px).
func _grid() -> Dictionary:
	var size := _canvas.size
	var width := minf(size.x, size.y * 16.0 / 9.0) * (1.0 - 2.0 * MARGIN)
	var height := width * 9.0 / 16.0
	var origin := (size - Vector2(width, height)) * 0.5
	return {origin = origin, size = Vector2(width, height), cell = Vector2(width / Model.COLS, height / Model.ROWS)}


func _draw_osd() -> void:
	if style == "off":
		return
	var grid := _grid()
	var cell: Vector2 = grid.cell
	var s := cell.y / 22.0
	var centre := _canvas.size * 0.5
	var layout: Dictionary = Model.LAYOUTS.get(style, {})
	if "horizon" in elements:
		_draw_horizon(centre, grid, s, layout)
	if "crosshair" in elements:
		Painter.crosshair(_canvas, centre, str(layout.get("crosshair", "default")), s)
	var font_size := maxi(8, int(round(cell.y * 0.78)))
	for item: Dictionary in items:
		var severity := int(item.severity)
		if severity == Model.CRITICAL and not OsdModel.blink_on(_clock):
			continue
		var color: Color = Painter.SEVERITY[clampi(severity, 0, Painter.SEVERITY.size() - 1)]
		var at: Vector2 = grid.origin + (Vector2(item.cell) + Vector2(0.5, 0.5)) * cell
		var text := str(item.text)
		var width := Painter.text_width(text, font_size)
		var icon := str(item.icon)
		var icon_w := cell.x * 1.6 if not icon.is_empty() else 0.0
		var start := at.x if int(item.align) < 0 else (at.x - (width + icon_w) * 0.5 if int(item.align) == 0 else at.x - width - icon_w)
		if not icon.is_empty():
			_draw_icon(icon, Vector2(start + icon_w * 0.45, at.y), cell, float(item.value), color, s)
		Painter.text(_canvas, Vector2(start + icon_w, at.y), text, font_size, color, -1)


func _draw_icon(icon: String, at: Vector2, cell: Vector2, value: float, color: Color, s: float) -> void:
	match icon:
		"battery":
			var r := Rect2(at - Vector2(cell.x * 0.32, cell.y * 0.38), Vector2(cell.x * 0.64, cell.y * 0.8))
			Painter.battery_icon(_canvas, r, value if is_finite(value) else 0.0, color, s * 0.8)
		"clock":
			Painter.icon_clock(_canvas, at, cell.y * 0.3, color)
		"arrow":
			if is_finite(value):
				Painter.home_arrow(_canvas, at, value, cell.y * 0.45, color)
		"antenna":
			var h := cell.y * 0.4
			Painter.stroke(_canvas, at + Vector2(0, h), at + Vector2(0, -h), 2.0 * s, color)
			Painter.polyline(_canvas, PackedVector2Array([at + Vector2(-h * 0.7, -h), at + Vector2(0, -h * 0.2), at + Vector2(h * 0.7, -h)]), 2.0 * s, color)


func _draw_horizon(centre: Vector2, grid: Dictionary, s: float, layout: Dictionary) -> void:
	var size: Vector2 = grid.size
	var line := Model.horizon(_pitch, _bank, _px_per_deg, _uptilt)
	var offset: Vector2 = line.offset
	var limit := AHI_MAX_OFFSET_SHARE * size.y
	if offset.length() > limit:
		offset = offset.normalized() * limit # pinned at the edge, like a character AHI at its last row
	var along: Vector2 = line.along
	var half := AHI_HALF_SHARE * size.x
	var gap := AHI_GAP_SHARE * size.x
	var mid := centre + offset
	if bool(layout.get("ladder", false)):
		_draw_rungs(centre, along, s, half, gap)
	# Betaflight/ArduPilot draw the horizon in dashes (character cells), INAV as a line.
	var dashed := style != "inav"
	for side: float in [-1.0, 1.0]:
		var a := mid + along * side * gap
		var b := mid + along * side * half
		if dashed:
			var parts := 6
			for j in parts:
				var t0 := float(j) / parts
				Painter.stroke(_canvas, a.lerp(b, t0), a.lerp(b, t0 + 0.6 / parts), 2.5 * s)
		else:
			Painter.stroke(_canvas, a, b, 2.5 * s)
	if bool(layout.get("sidebars", false)):
		var x := SIDEBAR_X_SHARE * size.x
		var h := SIDEBAR_HALF_SHARE * size.y
		for side: float in [-1.0, 1.0]:
			var top := centre + Vector2(side * x, -h)
			var bottom := centre + Vector2(side * x, h)
			Painter.stroke(_canvas, top, bottom, 1.5 * s)
			for k in range(-2, 3):
				var y := centre.y + h * float(k) / 2.0
				Painter.stroke(_canvas, Vector2(top.x, y), Vector2(top.x - side * 6.0 * s, y), 1.5 * s)


func _draw_rungs(centre: Vector2, along: Vector2, s: float, half: float, gap: float) -> void:
	var down := Vector2(-along.y, along.x)
	var size := maxi(8, int(round(13.0 * s)))
	for rung: int in LADDER_RUNGS:
		var off := down * (_pitch + _uptilt - float(rung)) * _px_per_deg
		if off.length() > AHI_MAX_OFFSET_SHARE * _grid().size.y:
			continue
		var mid := centre + off
		for side: float in [-1.0, 1.0]:
			var a := mid + along * side * gap * 1.6
			var b := mid + along * side * half * 0.55
			Painter.stroke(_canvas, a, b, 1.5 * s, Color(Painter.TEXT, 0.8))
			Painter.stroke(_canvas, b, b + down * signf(float(rung)) * 7.0 * s, 1.5 * s, Color(Painter.TEXT, 0.8))
		Painter.text(_canvas, mid + along * (half * 0.55 + 16.0 * s), str(absi(rung)), size, Painter.TEXT, 0)
