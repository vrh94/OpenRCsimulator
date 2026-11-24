extends RefCounted
## One list of controllers for the whole app: the joypads SDL reports through Godot's Input, plus virtual devices the
## app drives itself (an EdgeTX radio over USB serial, input/serial_radio_link.gd). Godot cannot mark a device
## connected from a script, so every identity lookup (which devices, name, GUID, info, SDL mapping) goes through
## here. A virtual device's axes and buttons are injected as ordinary InputEventJoypad events, so Input.get_joy_axis,
## Input.is_joy_button_pressed and _input handlers work for both kinds unchanged. With no virtual device registered,
## every function returns exactly what Input returns.

## id -> {name: String, guid: String, info: Dictionary}
static var _virtual: Dictionary = {}


static func connected() -> Array[int]:
	var ids: Array[int] = Input.get_connected_joypads()
	for id: int in _virtual:
		if not ids.has(id):
			ids.append(id)
	return ids


static func joy_name(id: int) -> String:
	return str(_virtual[id].name) if _virtual.has(id) else Input.get_joy_name(id)


static func joy_guid(id: int) -> String:
	return str(_virtual[id].guid) if _virtual.has(id) else Input.get_joy_guid(id)


static func joy_info(id: int) -> Dictionary:
	return (_virtual[id].info as Dictionary).duplicate(true) if _virtual.has(id) else Input.get_joy_info(id)


## A virtual device has no SDL gamepad mapping: like a USB radio, it reports raw axes and buttons.
static func is_known(id: int) -> bool:
	return false if _virtual.has(id) else Input.is_joy_known(id)


static func is_virtual(id: int) -> bool:
	return _virtual.has(id)


## The highest connection id that neither SDL nor another virtual device uses (SDL fills ids from 0 up), or -1.
static func free_id() -> int:
	var used := Input.get_connected_joypads()
	for id in range(15, -1, -1):
		if not used.has(id) and not _virtual.has(id):
			return id
	return -1


## Adds a virtual device and announces it like a hot-plugged joypad (Input.joy_connection_changed).
static func register(id: int, name: String, guid: String, info: Dictionary) -> void:
	_virtual[id] = {name = name, guid = guid, info = info.duplicate(true)}
	Input.joy_connection_changed.emit(id, true)


## Removes a virtual device: its axes return to centre and its buttons are released first, then the disconnect is
## announced. axes/buttons: how many of each the device has.
static func unregister(id: int, axes := 8, buttons := 32) -> void:
	if not _virtual.has(id):
		return
	# Unconditional: injected events are buffered until the next frame, so the current values may not show yet.
	for axis in axes:
		var motion := InputEventJoypadMotion.new()
		motion.device = id
		motion.axis = axis as JoyAxis
		motion.axis_value = 0.0
		Input.parse_input_event(motion)
	for button in buttons:
		var release := InputEventJoypadButton.new()
		release.device = id
		release.button_index = button as JoyButton
		release.pressed = false
		Input.parse_input_event(release)
	_virtual.erase(id)
	Input.joy_connection_changed.emit(id, false)
