# UI behavior for the standard-atmosphere-by-altitude draft and v4 preservation.
# Run: godot --headless --path . --audio-driver Dummy --script res://tests/test_ui_standard_column.gd
extends SceneTree

const WeatherSettings := preload("res://physics/wind_config.gd")
const WeatherDialog := preload("res://ui/weather_dialog.gd")
const Home := preload("res://ui/home.gd")
const Catalog := preload("res://app_state/aircraft_catalog.gd")
const UiDriver := preload("res://tests/ui_driver.gd")

var _failures: int = 0
var _accepted_config: Dictionary = {}
var ui: RefCounted


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL %s %s" % [label, detail])


func _initialize() -> void:
	ui = UiDriver.new(self)
	await _run()


func _run() -> void:
	TranslationServer.set_locale("en")
	var source_v3: Dictionary = WeatherSettings.upgrade_atmosphere(WeatherSettings.defaults(), {
		atmosphere_mode = "custom", field_elevation_m = 850.0, temperature_c = 24.0,
		qnh_hpa = 1002.0, relative_humidity_pct = 42.0,
	})
	var dialog: CanvasLayer = WeatherDialog.new(source_v3) as CanvasLayer
	dialog.applied.connect(_on_applied)
	root.add_child(dialog)
	await ui.settle()
	dialog.tab_container.current_tab = 2
	await ui.settle()
	_check("Atmosphere picker exposes the standard-column mode",
		dialog.atmosphere_mode_picker.item_count == 3
		and dialog.atmosphere_mode_picker.get_item_text(2) == "Standard atmosphere by altitude")
	_check("v3 custom source opens in its existing mode", dialog.atmosphere_mode_picker.selected == 1)

	_set_mode(dialog, 2)
	var field_edit: LineEdit = dialog.atmosphere_inputs["field_elevation_m"]
	var temp_edit: LineEdit = dialog.atmosphere_inputs["temperature_c"]
	var qnh_edit: LineEdit = dialog.atmosphere_inputs["qnh_hpa"]
	var humidity_edit: LineEdit = dialog.atmosphere_inputs["relative_humidity_pct"]
	_check("standard-column mode enables the field datum", field_edit.editable
		and dialog.atmosphere_sliders["field_elevation_m"].focus_mode == Control.FOCUS_ALL)
	_check("editable field datum retains its validated −500..4000 m range",
		dialog.atmosphere_sliders["field_elevation_m"].max_value == 4000.0
		and (dialog.find_child("field_elevation_mLabel", true, false) as Label).text
		== tr("Field elevation (−500 to 4000 m)"))
	_check("temperature, QNH, and humidity remain disabled", not temp_edit.editable and not qnh_edit.editable
		and not humidity_edit.editable and dialog.atmosphere_sliders["temperature_c"].focus_mode == Control.FOCUS_NONE)
	_check("standard-column note states the dry ISA geometric range and its reference status",
		dialog.atmosphere_note.text.contains("dry ISA") and dialog.atmosphere_note.text.contains("−500")
		and dialog.atmosphere_note.text.contains("11,000 m") and dialog.atmosphere_note.text.contains("not measured weather"),
		dialog.atmosphere_note.text)
	TranslationServer.set_locale("es")
	await ui.settle()
	_check("Spanish translates the new mode and its standard-atmosphere note",
		dialog.atmosphere_mode_picker.get_item_text(2) == "Atmósfera estándar por altitud"
		and dialog.atmosphere_note.text.contains("no meteorología medida"),
		"mode=%s note=%s" % [dialog.atmosphere_mode_picker.get_item_text(2), dialog.atmosphere_note.text])
	TranslationServer.set_locale("en")
	await ui.settle()

	field_edit.text = "1200"
	dialog._on_atmosphere_field_changed("1200", "field_elevation_m")
	# Disabled draft values must not leak into the applied v4 configuration, even if set programmatically.
	temp_edit.text = "99"
	qnh_edit.text = "700"
	humidity_edit.text = "101"
	dialog._on_apply()
	var expected_v4: Dictionary = WeatherSettings.upgrade_column(source_v3, {
		atmosphere_mode = "standard_column", field_elevation_m = 1200.0,
		temperature_c = source_v3.temperature_c, qnh_hpa = source_v3.qnh_hpa,
		relative_humidity_pct = source_v3.relative_humidity_pct,
	})
	_check("selecting standard column promotes v3 to v4 and retains inert weather drafts",
		_accepted_config == expected_v4 and _accepted_config.format == WeatherSettings.COLUMN_FORMAT,
		"actual=%s expected=%s" % [str(_accepted_config), str(expected_v4)])
	var expected_air: Dictionary = WeatherSettings.atmosphere(expected_v4)
	_check("standard-column preview samples the shared atmosphere kernel",
		expected_air.ok and dialog.atmosphere_preview.text == tr("Air density: %s kg/m³ · density altitude: %s m") % [
			String.num(float(expected_air.rho_kgm3), 3), String.num(float(expected_air.density_altitude_m), 0),
		], dialog.atmosphere_preview.text)
	var home: Control = Home.new() as Control
	root.add_child(home)
	await ui.settle()
	home.set_weather_config(expected_v4)
	_check("Home summarizes standard-column conditions and their reference status",
		home.weather_button.text.contains("Conditions")
		and home.weather_button.tooltip_text.contains("11,000 m")
		and home.weather_button.tooltip_text.contains("Standard ISA at field 1200.0 m")
		and home.weather_button.tooltip_text.contains("not measured weather"),
		"summary=%s tooltip=%s" % [home.weather_button.text, home.weather_button.tooltip_text])
	var helicopter_id: String = ""
	for candidate: String in Catalog.ids():
		if Catalog.is_rotorcraft(candidate):
			helicopter_id = candidate
			break
	if not helicopter_id.is_empty():
		home.aircraft_id = helicopter_id
		home.set_weather_config(expected_v4)
		_check("Home marks the altitude-varying mode as unsupported for helicopters",
			home.weather_button.tooltip_text.contains("does not support Standard atmosphere by altitude")
			and home.weather_button.tooltip_text.contains("Use steady wind and repeating gusts."),
			home.weather_button.tooltip_text)
	home.queue_free()
	await ui.settle()
	dialog.queue_free()
	await ui.settle()

	var source_v4: Dictionary = expected_v4.duplicate(true)
	var v4_dialog: CanvasLayer = WeatherDialog.new(source_v4) as CanvasLayer
	v4_dialog.applied.connect(_on_applied)
	root.add_child(v4_dialog)
	await ui.settle()
	v4_dialog.field_inputs["speed_mps"].text = "2.5"
	v4_dialog._on_field_changed("2.5", "speed_mps")
	v4_dialog._on_apply()
	_check("wind-only editing never downgrades v4 or changes its atmosphere mode",
		_accepted_config.get("format", "") == WeatherSettings.COLUMN_FORMAT
		and _accepted_config.get("atmosphere_mode", "") == "standard_column"
		and float(_accepted_config.get("speed_mps", -1.0)) == 2.5
		and float(_accepted_config.get("field_elevation_m", -1.0)) == 1200.0,
		str(_accepted_config))
	v4_dialog.queue_free()
	await ui.settle()
	await _surveyed_field(source_v3)
	await _ridge_preset(source_v3)
	print("all standard-column UI checks passed" if _failures == 0 else "%d standard-column UI checks failed" % _failures)
	quit(1 if _failures > 0 else 0)


## Triglav: a surveyed field flies at its own height, so the elevation box is read-only, shows that height and the
## saved value is kept for flat fields.
func _surveyed_field(source: Dictionary) -> void:
	var saved: Dictionary = source.duplicate(true)
	saved.field_elevation_m = 300.0
	var dialog: CanvasLayer = WeatherDialog.new(saved, null, null, null, 849.7) as CanvasLayer
	dialog.applied.connect(_on_applied)
	root.add_child(dialog)
	await ui.settle()
	dialog.tab_container.current_tab = 2
	await ui.settle()
	var field_edit: LineEdit = dialog.atmosphere_inputs["field_elevation_m"]
	for index: int in [1, 2, 0]:
		_set_mode(dialog, index)
		_check("surveyed field: elevation is read-only in mode %d" % index, not field_edit.editable
			and dialog.atmosphere_sliders["field_elevation_m"].focus_mode == Control.FOCUS_NONE
			and field_edit.text == "849.7", field_edit.text)
		_check("surveyed field: note names the surveyed height in mode %d" % index,
			dialog.atmosphere_note.text.contains("849.7 m"), dialog.atmosphere_note.text)
	_check("surveyed field: reference air previews the standard atmosphere at the field",
		dialog.atmosphere_preview.text.contains("1.128"), dialog.atmosphere_preview.text)
	_set_mode(dialog, 1)
	dialog.atmosphere_inputs["temperature_c"].text = "20"
	dialog._on_atmosphere_field_changed("20", "temperature_c")
	dialog._on_apply()
	_check("surveyed field: apply keeps the saved elevation for flat fields",
		float(_accepted_config.get("field_elevation_m", -1.0)) == 300.0
		and float(_accepted_config.get("temperature_c", -1.0)) == 20.0, str(_accepted_config))
	dialog.queue_free()
	await ui.settle()


## Option 2: ridge lift applies on a surveyed field, keeps its terrain flow through spatial edits, and a flat field's
## dialog refuses it with a note instead of applying.
func _ridge_preset(source: Dictionary) -> void:
	var entries: Array[Dictionary] = WeatherSettings.presets()
	var ridge := -1
	for index: int in entries.size():
		if entries[index].id == "spatial-ridge-lift-v1":
			ridge = index + 1
	_check("ridge lift is a weather preset", ridge > 0)
	if ridge <= 0:
		return
	var dialog: CanvasLayer = WeatherDialog.new(source.duplicate(true), null, null, null, 849.7) as CanvasLayer
	dialog.applied.connect(_on_applied)
	root.add_child(dialog)
	await ui.settle()
	_check("surveyed field: the ridge preset has no restriction caption",
		not dialog.preset_picker.get_item_text(ridge).contains("surveyed fields only"), dialog.preset_picker.get_item_text(ridge))
	dialog.preset_picker.select(ridge)
	dialog._on_preset_selected(ridge)
	await ui.settle()
	dialog.spatial_controls._field_inputs["reference_speed_mps"].text = "8"
	dialog._on_apply()
	var spatial: Dictionary = _accepted_config.get("spatial_wind", {})
	_check("surveyed field: ridge lift applies as terrain-following wind and keeps it through edits",
		str(spatial.get("format", "")) == "openrc-spatial-wind v3"
		and str(spatial.get("terrain_flow", {}).get("terrain", "")) == "field"
		and float(spatial.profile.reference_speed_mps) == 8.0, str(spatial))
	dialog.queue_free()
	await ui.settle()
	_accepted_config = {}
	var flat: CanvasLayer = WeatherDialog.new(source.duplicate(true)) as CanvasLayer
	flat.applied.connect(_on_applied)
	root.add_child(flat)
	await ui.settle()
	_check("flat field: the ridge preset is captioned for surveyed fields",
		flat.preset_picker.get_item_text(ridge).contains("surveyed fields only"), flat.preset_picker.get_item_text(ridge))
	flat.preset_picker.select(ridge)
	flat._on_preset_selected(ridge)
	await ui.settle()
	_check("flat field: choosing ridge lift explains instead of applying",
		flat.preset_picker.selected == 0 and flat.error_label.visible and flat.error_label.text.contains("surveyed terrain"),
		flat.error_label.text)
	flat.queue_free()
	await ui.settle()


func _set_mode(dialog: CanvasLayer, index: int) -> void:
	dialog.atmosphere_mode_picker.select(index)
	dialog._on_atmosphere_mode_selected(index)


func _on_applied(config: Dictionary) -> void:
	_accepted_config = config.duplicate(true)
