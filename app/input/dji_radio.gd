extends RefCounted
## RADIO-DJI-1: identity of DJI's FPV remote controllers on USB (the DJI FPV Remote Controller 3 that flies the
## Avata 2, and its predecessors). Plugged straight into the computer, the controller reports a HID joystick named
## "DJI Virtual Joystick", USB 2ca3:1021 (a user's lsusb report; not DJI documentation). It is treated as a radio:
## like every radio here it flies only after the "move the stick" calibration measures its axes, so no axis layout
## is assumed. Unlike a hobby radio its throttle stick springs back to the centre unless the stick is adjusted, so
## the calibration shows a note: hold the throttle fully down through every step.
##
## Not supported: DJI's motion controllers (RC Motion 2/3). No simulator documents them as USB joysticks; the older
## Motion Controller reports an absolute heading rather than stick positions, which this simulator cannot fly.

const VENDOR_ID := 0x2CA3
const NAME_TOKEN := "dji"
## The motion controllers' names, when one of them presents itself; they keep the generic joystick handling.
const MOTION_TOKENS := ["motion"]
const CALIBRATION_NOTE := "DJI FPV remote: its throttle stick springs back to the middle. Hold the THROTTLE fully DOWN through every calibration step, also while you move the other sticks. In flight the middle is half throttle unless you set the stick to stay where you leave it (see DJI's manual). The gimbal dial can tilt the FPV camera: Settings › Camera › Look & gimbal › FPV gimbal tilt channel."


## True for a DJI FPV remote: DJI's USB vendor ID, or "DJI" in the reported name, and not a motion controller.
static func matches(info: Dictionary) -> bool:
	var name := (str(info.get("name", "")) + " " + str(info.get("raw_name", ""))).to_lower()
	for token: String in MOTION_TOKENS:
		if token in name:
			return false
	return _vendor(info) == VENDOR_ID or NAME_TOKEN in name.split(" ", false) or name.begins_with(NAME_TOKEN)


## The calibration note for this device, or "".
static func calibration_note(info: Dictionary) -> String:
	return CALIBRATION_NOTE if matches(info) else ""


static func _vendor(info: Dictionary) -> int:
	var value: Variant = info.get("vendor_id", -1)
	if typeof(value) == TYPE_INT:
		return int(value)
	if typeof(value) == TYPE_STRING:
		var text: String = value.strip_edges().to_lower()
		if text.begins_with("0x") and text.substr(2).is_valid_hex_number():
			return text.substr(2).hex_to_int()
		if text.is_valid_int():
			return text.to_int()
	return -1
