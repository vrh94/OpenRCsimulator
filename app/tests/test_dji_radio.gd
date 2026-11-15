# RADIO-DJI-1: the DJI FPV Remote Controller 3 (Avata 2) on USB is recognized as a radio (input/dji_radio.gd).
#   - identity: DJI's USB vendor ID or "DJI" in the name; not the motion controllers; RadioMaster, gamepads and
#     look-alike names unchanged;
#   - connection: a DJI remote is a radio that needs calibration, even when SDL calls it a known gamepad; the TX16S and
#     a gamepad connect exactly as before;
#   - calibration: the unchanged wizard calibrates a spring-centred throttle held down through every step (any axis
#     layout), the released stick is half throttle, and releasing it during a step is caught; the note is shown.
# Run: godot --headless --path . --script res://tests/test_dji_radio.gd
extends SceneTree

const DjiRadio := preload("res://input/dji_radio.gd")
const RcInput := preload("res://input/rc_input.gd")
const Calibration := preload("res://input/rc_calibration.gd")
const ControllerProfile := preload("res://input/controller_profile.gd")
const CalibrationView := preload("res://ui/controls/calibration_view.gd")

const DJI := { name = "DJI Virtual Joystick", vendor_id = 0x2CA3, product_id = 0x1021, guid = "dji-guid" }
const TX16S := { name = "RadioMaster TX16S Joystick", vendor_id = 0x1209, product_id = 0x4F54, guid = "tx16s-guid" }
const XBOX := { name = "Xbox Wireless Controller", vendor_id = 0x045E, product_id = 0x0B13, guid = "xbox-guid", known = true }

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
	_identity()
	_connection()
	_calibration()
	_note()
	print("all %d DJI radio checks passed" % _count if _failures == 0 else "%d of %d failed" % [_failures, _count])
	quit(1 if _failures > 0 else 0)


func _identity() -> void:
	_check("identity: DJI Virtual Joystick", DjiRadio.matches(DJI))
	_check("identity: DJI vendor ID alone", DjiRadio.matches({ name = "Joystick", vendor_id = 0x2CA3 }))
	_check("identity: vendor ID as a hex string", DjiRadio.matches({ name = "Joystick", vendor_id = "0x2ca3" }))
	_check("identity: DJI in the name alone", DjiRadio.matches({ name = "DJI FPV Remote Controller 3" }))
	_check("identity: not the motion controller", not DjiRadio.matches({ name = "DJI RC Motion 3", vendor_id = 0x2CA3 }))
	_check("identity: not the TX16S", not DjiRadio.matches(TX16S))
	_check("identity: not a gamepad", not DjiRadio.matches(XBOX))
	_check("identity: not a look-alike name", not DjiRadio.matches({ name = "Adjinator Stick", vendor_id = 0x1234 }))
	_check("identity: TX16S still looks like a radio", RcInput.looks_like_radio(TX16S.name))


func _connection() -> void:
	var known_dji := DJI.duplicate()
	known_dji.known = true # SDL may map it as a gamepad; it must still calibrate as a radio
	var radio := RcInput.new()
	radio.connect_device(3, known_dji)
	_check("connect: a DJI remote is a radio", radio.profile.get("kind", "") == "radio", str(radio.profile.get("kind")))
	_check("connect: it needs calibration (no assumed layout)", radio.profile_source == "unconfigured"
		and radio.profile_error.contains("calibration"), radio.profile_error)
	var tx := RcInput.new()
	tx.connect_device(4, TX16S)
	_check("connect: the TX16S is unchanged (a radio awaiting calibration)", tx.profile.get("kind", "") == "radio" and tx.profile_source == "unconfigured")
	var pad := RcInput.new()
	pad.connect_device(5, XBOX)
	_check("connect: a gamepad keeps its defaults", pad.profile_source == "gamepad" and pad.profile.get("kind", "") == "gamepad")


## Ten axes at rest: the DJI-like layout under test puts roll 0, pitch 1, throttle 2 (sprung, held down), yaw 3,
## gimbal dial 4. The wizard measures it; nothing in the code assumes it.
static func _axes(roll := 0.0, pitch := 0.0, throttle := -1.0, yaw := 0.0) -> PackedFloat64Array:
	var a := PackedFloat64Array()
	a.resize(RcInput.AXES)
	a[0] = roll
	a[1] = pitch
	a[2] = throttle
	a[3] = yaw
	return a


static func _hold(wizard: RefCounted, axes: PackedFloat64Array, samples := 6) -> void:
	for i in samples:
		wizard.sample(axes)


func _calibration() -> void:
	var w := Calibration.new()
	_hold(w, _axes())
	w.advance(_axes()) # rest: sticks centred, throttle held down
	_hold(w, _axes(0, 0, 1.0))
	_hold(w, _axes())
	w.advance(_axes()) # throttle full, then held down again
	for step: Array in [[0, 1.0], [1, 1.0], [3, 1.0]]: # roll right, pitch back, yaw right (positive here)
		var held := _axes()
		held[step[0]] = step[1]
		_hold(w, held)
		w.advance(held)
		var opposite := _axes()
		opposite[step[0]] = -step[1]
		_hold(w, opposite)
		_hold(w, _axes())
		w.advance(_axes())
	_check("calibration: completes with the throttle held down", w.done(), w.error)
	if not w.done():
		return
	var mapping: Dictionary = w.profile
	_check("calibration: axes measured", int(mapping.roll.axis) == 0 and int(mapping.pitch.axis) == 1 and int(mapping.throttle.axis) == 2
		and int(mapping.yaw.axis) == 3, str(mapping))
	_check("calibration: held down is idle", is_equal_approx(RcInput.normalize_throttle(-1.0, mapping.throttle), 0.0))
	_check("calibration: the released (centred) stick is half throttle", is_equal_approx(RcInput.normalize_throttle(0.0, mapping.throttle), 0.5))
	var upgraded := ControllerProfile.upgrade_legacy(mapping)
	_check("calibration: the profile validates as a radio", bool(ControllerProfile.validate(upgraded).ok) and upgraded.throttle_mode == "radio_absolute",
		str(ControllerProfile.validate(upgraded).errors))
	# Letting the throttle spring back during a stick step is caught, not mis-assigned.
	var slip := Calibration.new()
	_hold(slip, _axes())
	slip.advance(_axes())
	_hold(slip, _axes(0, 0, 1.0))
	_hold(slip, _axes())
	slip.advance(_axes())
	var released := _axes(1.0, 0, 0.0) # roll right, throttle let go to the middle
	_hold(slip, released)
	slip.advance(released)
	_check("calibration: a released throttle during a step is refused", slip.step == 2 and slip.error.contains("More than one axis"), slip.error)


func _note() -> void:
	_check("note: shown for a DJI remote", DjiRadio.calibration_note(DJI).contains("THROTTLE fully DOWN"))
	_check("note: none for the TX16S", DjiRadio.calibration_note(TX16S).is_empty())
	var view := CalibrationView.new()
	get_root().add_child(view)
	view.set_device_note(DjiRadio.calibration_note(DJI))
	_check("note: the calibration view shows it", view.device_note_label.visible and not view.device_note_label.text.is_empty())
	view.set_device_note("")
	_check("note: hidden for other radios", not view.device_note_label.visible)
	view.queue_free()
