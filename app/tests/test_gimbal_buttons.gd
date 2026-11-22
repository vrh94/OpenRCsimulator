# GIMBAL-2 (2026-11-22): the FPV gimbal on radio buttons, and press-to-assign in Settings › Camera › Gimbal controls.
# FpvHead: "move" buttons turn the servo at its speed and leave it there, the centre button brings it back, "look"
# buttons point it to the end of its travel while held; a lost radio returns it to the centre; the travel is never
# exceeded with a channel added. Settings: Detect takes the channel that moves (never a flight axis or another device),
# a button press assigns a role (one button per role), Esc cancels, and the settings validate and normalize.
# Run: godot --headless --path . --audio-driver Dummy --script res://tests/test_gimbal_buttons.gd
extends SceneTree

const FpvHead := preload("res://render/camera/fpv_head.gd")
const CameraSettings := preload("res://render/camera/camera_settings.gd")
const SettingsScreen := preload("res://ui/settings_screen.gd")
const DisplayPreferences := preload("res://app_state/display_preferences.gd")

var _checks := 0
var _failures := 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%s %s %s" % ["ok  " if ok else "FAIL", label, detail])


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_head()
	_settings_values()
	await _screen()
	print("%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _config(extra: Dictionary) -> Dictionary:
	var c: Dictionary = CameraSettings.DEFAULTS.duplicate(true)
	c.merge(extra, true)
	return c


func _step(head: FpvHead, held: Array, seconds: float, axis_value: float = NAN, radio := true) -> void:
	var read_axis := func(_axis: int) -> float: return axis_value
	var read_button := func(button: int) -> Variant: return (button in held) if radio else null
	var dt := 1.0 / 60.0
	for i in roundi(seconds / dt):
		head.update_gimbal(read_axis, [], dt, read_button)


func _head() -> void:
	var head := FpvHead.new()
	head.configure(_config({camera_fpv_gimbal_pan_left_button = 4, camera_fpv_gimbal_pan_right_button = 5,
		camera_fpv_gimbal_tilt_up_button = 6, camera_fpv_gimbal_tilt_down_button = 7, camera_fpv_gimbal_centre_button = 8}))
	_check("buttons alone enable the gimbal", head.gimbal_enabled() and head.bound_buttons() == [4, 5, 6, 7, 8])
	_step(head, [5], 0.25)
	_check("move: holding pan right turns right at the servo speed (180°/s)", absf(head.gimbal.x - 45.0) < 0.5,
		"pan %.2f" % head.gimbal.x)
	_step(head, [], 0.5)
	_check("and the camera stays there when released", absf(head.gimbal.x - 45.0) < 0.5)
	_step(head, [5], 2.0)
	_check("it stops at the pan travel (±90°)", is_equal_approx(head.gimbal.x, 90.0) and is_equal_approx(head.button_offset.x, 90.0))
	_step(head, [6], 1.0)
	_check("tilt up stops at the tilt travel (±45°)", is_equal_approx(head.gimbal.y, 45.0))
	_step(head, [8], 1.0)
	_check("the centre button brings it back", head.gimbal == Vector2.ZERO and head.button_offset == Vector2.ZERO)
	_step(head, [4, 5], 0.5)
	_check("left and right together cancel", head.gimbal == Vector2.ZERO)
	_step(head, [4, 7], 0.2)
	_check("pan left and tilt down move left and down", head.gimbal.x < -30.0 and head.gimbal.y < -30.0)
	_step(head, [], 1.0, NAN, false)
	_check("a lost radio returns the camera to the centre", head.gimbal == Vector2.ZERO and head.button_offset == Vector2.ZERO)
	head.configure(_config({camera_fpv_gimbal_pan_axis = 6, camera_fpv_gimbal_pan_right_button = 5}))
	_step(head, [5], 2.0, 0.5)
	var half := FpvHead.command(0.5, 90.0, false)
	_check("a channel and buttons add, within the travel", is_equal_approx(head.gimbal.x, 90.0)
		and is_equal_approx(head.button_offset.x, 90.0 - half), "pan %.2f offset %.2f" % [head.gimbal.x, head.button_offset.x])
	_step(head, [], 1.0, -0.5)
	_check("turning the channel back keeps the buttons' share", is_equal_approx(head.gimbal.x, -half + 90.0 - half),
		"pan %.2f" % head.gimbal.x)
	head.configure(_config({camera_fpv_gimbal_pan_left_button = 1, camera_fpv_gimbal_tilt_down_button = 2,
		camera_fpv_gimbal_button_mode = "look", camera_fpv_gimbal_speed = "instant"}))
	_step(head, [1], 0.1)
	_check("look: holding pan left points to the end of the travel", is_equal_approx(head.gimbal.x, -90.0))
	_step(head, [], 0.1)
	_check("and back to the centre on release", head.gimbal == Vector2.ZERO)
	_step(head, [2], 0.1)
	_check("look down works the same", is_equal_approx(head.gimbal.y, -45.0))
	head.configure(_config({}))
	_check("with nothing bound the gimbal stays off", not head.gimbal_enabled())
	head.configure(_config({camera_fpv_gimbal_pan_right_button = 3, camera_fpv_gimbal_invert_pan = true}))
	_step(head, [3], 0.2)
	_check("a named button is not reversed by the channel's reverse toggle", head.gimbal.x > 30.0)


func _settings_values() -> void:
	_check("defaults validate with no gimbal buttons", CameraSettings.errors(CameraSettings.DEFAULTS).is_empty()
		and int(CameraSettings.DEFAULTS.camera_fpv_gimbal_centre_button) == -1 and CameraSettings.DEFAULTS.camera_fpv_gimbal_button_mode == "move")
	_check("a button number and a mode validate", CameraSettings.errors({camera_fpv_gimbal_tilt_up_button = 12,
		camera_fpv_gimbal_button_mode = "look"}).is_empty())
	_check("an out-of-range button, a float or an unknown mode is refused",
		not CameraSettings.errors({camera_fpv_gimbal_tilt_up_button = 128}).is_empty()
		and not CameraSettings.errors({camera_fpv_gimbal_pan_left_button = 2.0}).is_empty()
		and not CameraSettings.errors({camera_fpv_gimbal_button_mode = "spin"}).is_empty())
	var n: Dictionary = CameraSettings.normalized({camera_fpv_gimbal_centre_button = 9})
	_check("normalized keeps the buttons and mode", n.camera_fpv_gimbal_centre_button == 9 and n.camera_fpv_gimbal_pan_left_button == -1
		and n.camera_fpv_gimbal_button_mode == "move")


func _button_event(device: int, button: int, pressed := true) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.device = device
	e.button_index = button
	e.pressed = pressed
	return e


func _motion(device: int, axis: int, value: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.device = device
	e.axis = axis
	e.axis_value = value
	return e


func _screen() -> void:
	var path := "user://test_gimbal_buttons_display.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	root.add_child(viewport)
	var screen := SettingsScreen.new(DisplayPreferences.new(path), "en")
	screen.gimbal_radio = func() -> Dictionary: return {device = 0, reserved = [0, 1, 2, 3]}
	viewport.add_child(screen)
	await process_frame
	screen._show_category(SettingsScreen.CATEGORIES.find("Camera"))
	screen._show_camera_part(SettingsScreen.CAMERA_PARTS.find("Gimbal controls"))
	await process_frame
	var tilt_up: Button = screen._gimbal_button_controls.tilt_up
	_check("the Gimbal controls part lists five button roles, unset", screen._gimbal_button_controls.size() == 5
		and tilt_up.text == "Not set" and tilt_up.is_visible_in_tree())
	tilt_up.pressed.emit()
	_check("clicking a role listens for a radio button", tilt_up.text == "Press a radio button…")
	_check("another device's button is ignored", not screen.gimbal_capture_event(_button_event(1, 3)) and tilt_up.text == "Press a radio button…")
	_check("a radio button press assigns it", screen.gimbal_capture_event(_button_event(0, 3))
		and int(screen._draft.camera_fpv_gimbal_tilt_up_button) == 3 and tilt_up.text == "Button 4")
	(screen._gimbal_button_controls.centre as Button).pressed.emit()
	screen.gimbal_capture_event(_button_event(0, 3))
	_check("the same button moves to the new role and leaves the old one", int(screen._draft.camera_fpv_gimbal_centre_button) == 3
		and int(screen._draft.camera_fpv_gimbal_tilt_up_button) == -1 and tilt_up.text == "Not set")
	(screen._gimbal_button_controls.pan_left as Button).pressed.emit()
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_check("Esc cancels without a change", screen.gimbal_capture_event(esc) and int(screen._draft.camera_fpv_gimbal_pan_left_button) == -1
		and screen._gimbal_capture.is_empty())
	screen.begin_gimbal_capture("camera_fpv_gimbal_pan_axis", "axis")
	_check("Detect ignores a flight-stick axis", not screen.gimbal_capture_event(_motion(0, 1, 1.0))
		and int(screen._draft.camera_fpv_gimbal_pan_axis) == -1)
	screen.gimbal_capture_event(_motion(0, 6, 0.2))
	_check("and a small wobble", int(screen._draft.camera_fpv_gimbal_pan_axis) == -1 and not screen._gimbal_capture.is_empty())
	screen.gimbal_capture_event(_motion(0, 6, 0.8))
	_check("a knob turned past half its travel becomes the pan channel", int(screen._draft.camera_fpv_gimbal_pan_axis) == 6
		and screen._camera_fpv_gimbal_pan_axis_picker.get_selected_metadata() == 6)
	(screen.find_child("CameraFpvGimbalCentreButtonClear", true, false) as Button).pressed.emit()
	_check("Clear unsets a role", int(screen._draft.camera_fpv_gimbal_centre_button) == -1)
	screen.begin_gimbal_capture("camera_fpv_gimbal_pan_left_button", "button")
	screen._gimbal_capture.until_msec = 0
	screen._process(0.0)
	_check("an unanswered capture gives up", screen._gimbal_capture.is_empty()
		and (screen._gimbal_button_controls.pan_left as Button).text == "Not set")
	_check("the draft with gimbal buttons validates", CameraSettings.errors(screen._draft).is_empty(), str(CameraSettings.errors(screen._draft)))
	viewport.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
