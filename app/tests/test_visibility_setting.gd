# Option 7b: Settings → Display → Visibility offers Normal (23 km), Hazy (12 km) and Clear air (40 km), Normal by
# default, on the Display page after RC circuit (the Graphics page has no room for another row at 1080p). It saves with Keep,
# reverts with Back, returns to Normal with Restore graphics defaults, and takes effect when the next world is built
# (World._new_build_context -> Atmosphere.apply_visibility_preference); a running flight keeps one consistent value.
# Run: python3 tools/godot/run_checked.py --timeout 60 -- "$(app/get-godot.sh)" --headless --path app --script res://tests/test_visibility_setting.gd
extends SceneTree

const Atmosphere := preload("res://render/atmosphere.gd")
const DisplayPreferences := preload("res://app_state/display_preferences.gd")
const SettingsScreen := preload("res://ui/settings_screen.gd")
const Spec := preload("res://spec.gd")
const World := preload("res://render/world/world.gd")
const PREFS := "user://test_visibility_setting_display.cfg"

var _failures := 0


func _check(label: String, ok: bool, detail := "") -> void:
	if ok:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL %s %s" % [label, detail])


func _initialize() -> void:
	var original: float = Atmosphere.visibility_m
	_preferences()
	_atmosphere()
	await _settings()
	Atmosphere.visibility_m = original
	Atmosphere._visibility_preference = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS))
	print("all visibility setting checks passed" if _failures == 0 else "%d visibility setting check(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)


func _preferences() -> void:
	var levels := DisplayPreferences.VISIBILITY_LEVELS.duplicate()
	levels.sort()
	var presets: Array = Atmosphere.VISIBILITY_PRESETS.keys()
	presets.sort()
	_check("the Settings levels mirror the atmosphere's presets", levels == presets, str(levels))
	_check("Normal is the default", DisplayPreferences.DEFAULTS.visibility == "default")
	_check("the default preset keeps the calibrated 23 km",
		is_equal_approx(float(Atmosphere.VISIBILITY_PRESETS["default"]), Spec.ATMOSPHERE.visibility_m))
	var raw: Dictionary = DisplayPreferences.load_from("user://missing_visibility_display.cfg").duplicate()
	raw.visibility = "foggy"
	var checked: Dictionary = DisplayPreferences.validate(raw)
	_check("an unknown visibility is rejected", not checked.ok and ", ".join(checked.errors).contains("visibility"),
		str(checked.get("errors", [])))


func _atmosphere() -> void:
	Atmosphere._visibility_preference = ""
	Atmosphere.visibility_m = Spec.ATMOSPHERE.visibility_m
	Atmosphere.apply_visibility_preference()
	_check("without a stored choice the visibility is untouched", is_equal_approx(Atmosphere.visibility_m, 23000.0))
	Atmosphere.set_visibility_preference("clear")
	_check("a stored choice does not change a running flight", is_equal_approx(Atmosphere.visibility_m, 23000.0))
	World._new_build_context(null, {}, Callable(), {}, {}, {})
	_check("the next world adopts Clear air: 40 km", is_equal_approx(Atmosphere.visibility_m, 40000.0),
		str(Atmosphere.visibility_m))
	_check("Clear air triples the contrast left at Ljubljana's 17 km", exp(-Atmosphere.beta() * 17000.0) > 2.5 * exp(-3.912 / 23000.0 * 17000.0))
	Atmosphere.set_visibility_preference("hazy")
	Atmosphere.apply_visibility_preference()
	_check("Hazy is 12 km", is_equal_approx(Atmosphere.visibility_m, 12000.0))
	Atmosphere.set_visibility_preference("thick")
	Atmosphere.apply_visibility_preference()
	_check("an unknown choice falls back to Normal", is_equal_approx(Atmosphere.visibility_m, Spec.ATMOSPHERE.visibility_m))


func _settings() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS))
	var settings := SettingsScreen.new(DisplayPreferences.new(PREFS), "en")
	root.add_child(settings)
	await process_frame
	var picker: OptionButton = settings.find_child("Visibility", true, false)
	var texts: Array[String] = []
	if picker != null:
		for i: int in picker.item_count:
			texts.append(picker.get_item_text(i))
	_check("Settings > Graphics shows Visibility: Normal, Hazy, Clear air, with Normal selected", picker != null
		and texts == ["Normal", "Hazy", "Clear air"] and picker.get_item_metadata(picker.selected) == "default", str(texts))
	if picker == null:
		return
	var rc_track: OptionButton = settings.find_child("RcTrack", true, false)
	_check("it has its own row on the Display page, after RC circuit", rc_track != null
		and picker.get_parent().get_parent() == rc_track.get_parent().get_parent()
		and picker.get_parent().get_index() == rc_track.get_parent().get_index() + 1)
	_check("its tooltip says when it applies", picker.tooltip_text.contains("next flight"))
	var previews: Array = []
	settings.presentation_changed.connect(func(config: Dictionary) -> void: previews.append(config.get("visibility", "")))
	picker.select(2)
	picker.item_selected.emit(2)
	_check("choosing Clear air passes it on", previews.back() == "clear" if not previews.is_empty() else false, str(previews))
	_check("an unkept choice is not saved yet", DisplayPreferences.load_from(PREFS).visibility == "default")
	settings.keep_changes()
	_check("Keep saves Clear air", DisplayPreferences.load_from(PREFS).visibility == "clear")
	picker.select(1)
	picker.item_selected.emit(1)
	settings._revert()
	_check("Back reverts an unkept Hazy to the kept Clear air", settings._draft.visibility == "clear"
		and picker.get_item_metadata(picker.selected) == "clear")
	settings._restore_graphics_defaults()
	_check("Restore graphics defaults returns Visibility to Normal", settings._draft.visibility == "default"
		and picker.get_item_metadata(picker.selected) == "default")
	settings.queue_free()
	await process_frame
	TranslationServer.set_locale("de")
	var localized := SettingsScreen.new(DisplayPreferences.new(PREFS), "de")
	root.add_child(localized)
	await process_frame
	var german: OptionButton = localized.find_child("Visibility", true, false)
	_check("reopening shows the saved Clear air, translated", german != null and german.get_item_metadata(german.selected) == "clear"
		and german.get_item_text(2) == "Klare Luft", german.get_item_text(2) if german else "")
	localized.queue_free()
	await process_frame
	TranslationServer.set_locale("en")
