# EdgeTX radio over USB serial (input/serial_radio_link.gd) and the shared controller list (input/joypad_directory.gd).
# The radio's simlnk.lua sends C (channels) and H (hello) lines; the link presents the channels as the same radio's
# Classic USB joystick (identity, axes and buttons), drops it when frames stop, and sends telemetry 10 times a second.
# No helper process and no hardware: lines are fed directly, time and output are injected.
# Run: python3 tools/godot/run_checked.py --timeout 60 -- "$(app/get-godot.sh)" --headless --path app --script res://tests/test_serial_radio_link.gd
extends SceneTree

const JoypadDirectory := preload("res://input/joypad_directory.gd")
const SerialRadioLink := preload("res://input/serial_radio_link.gd")
const ControllerService := preload("res://input/controller_service.gd")
const RadioTelemetry := preload("res://sim/radio_telemetry.gd")

var _failures := 0
var _clock := 100000
var _written: PackedStringArray = []
var _events: Array = []


func _check(label: String, ok: bool, detail := "") -> void:
	if ok:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL %s %s" % [label, detail])


func _initialize() -> void:
	_directory()
	_identity()
	_link()
	_hello_timeout()
	print("all serial radio link checks passed" if _failures == 0 else "%d serial radio link check(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)


func _directory() -> void:
	_check("directory: without virtual devices it lists exactly Input's joypads",
		JoypadDirectory.connected() == Input.get_connected_joypads())
	var id := JoypadDirectory.free_id()
	_check("directory: a free id exists and SDL does not use it", id >= 0 and not Input.get_connected_joypads().has(id), str(id))
	var seen: Array = []
	var on_change := func(device: int, connected: bool) -> void: seen.append([device, connected])
	Input.joy_connection_changed.connect(on_change)
	JoypadDirectory.register(id, "Virtual radio", "guid-x", {vendor_id = 1, product_id = 2, backend = "serial"})
	_check("directory: registering announces a connection", seen == [[id, true]], str(seen))
	_check("directory: the virtual device is listed with its identity", JoypadDirectory.connected().has(id)
		and JoypadDirectory.joy_name(id) == "Virtual radio" and JoypadDirectory.joy_guid(id) == "guid-x"
		and int(JoypadDirectory.joy_info(id).vendor_id) == 1 and not JoypadDirectory.is_known(id) and JoypadDirectory.is_virtual(id))
	var info := JoypadDirectory.joy_info(id)
	info.vendor_id = 99
	_check("directory: info is a copy", int(JoypadDirectory.joy_info(id).vendor_id) == 1)
	var motion := InputEventJoypadMotion.new()
	motion.device = id
	motion.axis = JOY_AXIS_LEFT_Y
	motion.axis_value = 0.5
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	_check("directory: injected axis events read back through Input", is_equal_approx(Input.get_joy_axis(id, JOY_AXIS_LEFT_Y), 0.5))
	JoypadDirectory.unregister(id)
	Input.flush_buffered_events()
	_check("directory: unregistering centres axes and announces the disconnect", Input.get_joy_axis(id, JOY_AXIS_LEFT_Y) == 0.0
		and seen.back() == [id, false] and not JoypadDirectory.connected().has(id))
	Input.joy_connection_changed.disconnect(on_change)


func _identity() -> void:
	# The user's Zorro as an EdgeTX 2.12.5 USB joystick (as stored in their controller profile).
	var zorro := SerialRadioLink.joystick_identity("Radiomaster Zorro Serial Port", "zorro", "2.12.5")
	_check("identity: the Zorro's joystick name", zorro.name == "OpenTX Radiomaster Zorro Joystick", str(zorro.name))
	_check("identity: SDL's GUID for that joystick (CRC 401f, 1209:4f54, version 0x0212)",
		zorro.guid == "03001f4009120000544f000012020000", str(zorro.guid))
	_check("identity: pid.codes vendor and EdgeTX's joystick product", zorro.vendor_id == 0x1209 and zorro.product_id == 0x4F54)
	var unknown := SerialRadioLink.joystick_identity("", "tx16s", "")
	_check("identity: without USB strings the radio name is used", unknown.name == "OpenTX EdgeTX tx16s Joystick", str(unknown.name))
	_check("axes: 0 and 2047 are the ends, 1024 is (almost) centre like the USB joystick",
		SerialRadioLink.axis_value(0) == -1.0 and is_equal_approx(SerialRadioLink.axis_value(2047), 1.0)
		and absf(SerialRadioLink.axis_value(1024)) < 0.001, "%f %f %f" % [SerialRadioLink.axis_value(0), SerialRadioLink.axis_value(2047), SerialRadioLink.axis_value(1024)])
	var monotonic := true
	for v in range(1, 2048):
		monotonic = monotonic and SerialRadioLink.axis_value(v) >= SerialRadioLink.axis_value(v - 1)
	_check("axes: monotonic over the whole range", monotonic)


func _frame(values: Array) -> String:
	var payload := "C"
	for v: int in values:
		payload += "%03X" % v
	return payload + "*%02X" % RadioTelemetry.checksum(payload)


func _channels(overrides: Dictionary) -> Array:
	var out: Array = []
	for ch in 16:
		out.append(int(overrides.get(ch, 1024)))
	return out


func _new_link() -> Node:
	var link: Node = SerialRadioLink.new()
	link.now_ms = func() -> int: return _clock
	link.write = func(text: String) -> void: _written.append(text)
	root.add_child(link)
	return link


func _link() -> void:
	var link := _new_link()
	var telemetry := {alt = 120.0, vs = 1.5, gs = 54.0, aspd = 61.0, hdg = 52.0, pitch = 3.0, roll = -10.0, mode = "ANGL",
		armed = true, time = 93.0, thr = 48.0, volt = 16.4, curr = 12.5, mah = 734.0, pct = 62.0, dist = 612.0,
		home_dir = 190.0, lat = NAN, lon = NAN, aircraft = "Ugly Stik"}
	link.telemetry_source = func() -> Dictionary: return telemetry
	link.feed("#PORT /dev/cu.usbmodem1234|Radiomaster Zorro Serial Port\n")
	_check("link: port and USB product from the helper", link.port == "/dev/cu.usbmodem1234" and link.usb_product == "Radiomaster Zorro Serial Port")
	link.feed(_frame(_channels({})) + "\n")
	_check("link: no device before the hello line (identity needs the EdgeTX version)", link.device_id < 0)
	link.feed("H,zorro,2.12.5*%02X\n" % RadioTelemetry.checksum("H,zorro,2.12.5"))
	_clock += 50
	# Ail full left, Ele full up (clamped), Thr low, Rud 1/4 right; CH9 (SA) on, CH10 off.
	link.feed(_frame(_channels({0: 0, 1: 2047, 2: 0, 3: 1536, 8: 2048 - 1, 9: 0})).substr(0, 20))
	link.feed(_frame(_channels({0: 0, 1: 2047, 2: 0, 3: 1536, 8: 2048 - 1, 9: 0})).substr(20) + "\r\n")
	Input.flush_buffered_events()
	var id: int = link.device_id
	_check("link: device announced after the hello, joined across split reads", id >= 0 and JoypadDirectory.connected().has(id), str(id))
	var devices := ControllerService.observed_devices()
	var mine: Dictionary = {}
	for d: Dictionary in devices:
		if int(d.id) == id:
			mine = d
	_check("link: the controller service sees the Zorro joystick identity, as a radio over serial",
		mine.get("name", "") == "OpenTX Radiomaster Zorro Joystick" and mine.get("guid", "") == "03001f4009120000544f000012020000"
		and mine.get("backend", "") == "serial" and mine.get("kind", "") == "radio" and not bool(mine.get("known", true)), str(mine))
	_check("link: CH1-4 reach Godot axes 0-3 like the USB joystick", Input.get_joy_axis(id, JOY_AXIS_LEFT_X) == -1.0
		and is_equal_approx(Input.get_joy_axis(id, JOY_AXIS_LEFT_Y), 1.0) and Input.get_joy_axis(id, JOY_AXIS_RIGHT_X) == -1.0
		and is_equal_approx(Input.get_joy_axis(id, JOY_AXIS_RIGHT_Y), SerialRadioLink.axis_value(1536)))
	_check("link: CH9 above centre presses button 0, CH10 below leaves button 1 up",
		Input.is_joy_button_pressed(id, JOY_BUTTON_A) and not Input.is_joy_button_pressed(id, JOY_BUTTON_B))
	var errors_before: int = link.bad_lines
	link.feed("C000000000000000000000000000000000000000000000000*00\n")
	Input.flush_buffered_events()
	_check("link: a frame with a bad checksum is counted and ignored", link.bad_lines == errors_before + 1
		and Input.get_joy_axis(id, JOY_AXIS_LEFT_X) == -1.0)
	link.feed(_frame(_channels({0: 0, 1: 2047, 2: 0, 3: 1536, 8: 0})) + "\n")
	Input.flush_buffered_events()
	_check("link: a switch back below centre releases its button", not Input.is_joy_button_pressed(id, JOY_BUTTON_A))
	# Telemetry
	_written.clear()
	link.tick()
	var joined := "".join(_written)
	_check("telemetry: first send has the identity, attitude, mode, battery and navigation lines",
		_written.size() == 5 and joined.contains("I,OpenRC,Ugly Stik*") and joined.contains("A,120.0,1.5,54.0,61.0,52,3.0,-10.0*")
		and joined.contains("M,ANGL,1,93,48*") and joined.contains("B,16.40,12.5,734,62*") and joined.contains("N,612,190,,*"), joined)
	var valid := true
	for text in _written:
		var line := text.strip_edges()
		var star := line.rfind("*")
		valid = valid and text.ends_with("\n") and RadioTelemetry.checksum(line.substr(0, star)) == line.substr(star + 1).hex_to_int()
	_check("telemetry: every line ends in a newline and carries a valid checksum", valid)
	_written.clear()
	_clock += 40
	link.tick()
	_check("telemetry: at most 10 sends a second", _written.is_empty())
	_clock += 70
	link.feed(_frame(_channels({})) + "\n")
	link.tick()
	_check("telemetry: odd sends carry attitude and mode only", _written.size() == 2, str(_written))
	# Loss of frames
	var announced: Array = []
	var on_change := func(device: int, connected: bool) -> void: announced.append([device, connected])
	Input.joy_connection_changed.connect(on_change)
	_clock += 600
	link.tick()
	Input.flush_buffered_events()
	_check("link: no frames for 0.5 s drops the device, centres its axes and announces it",
		link.device_id < 0 and not JoypadDirectory.connected().has(id) and announced == [[id, false]]
		and Input.get_joy_axis(id, JOY_AXIS_LEFT_X) == 0.0, str(announced))
	_written.clear()
	_clock += 200
	link.tick()
	_check("telemetry: nothing is sent while no radio is present", _written.is_empty())
	link.feed(_frame(_channels({})) + "\n")
	_check("link: the next frame brings the radio back (same identity)", link.device_id >= 0
		and JoypadDirectory.joy_guid(link.device_id) == "03001f4009120000544f000012020000")
	link.feed("#GONE\n")
	_check("link: the helper's #GONE ends the device and the port", link.device_id < 0 and link.port == "")
	Input.joy_connection_changed.disconnect(on_change)
	link.queue_free()


func _hello_timeout() -> void:
	var link := _new_link()
	link.feed("#PORT /dev/ttyACM0|Jumper T-Pro Serial Port\n")
	link.feed(_frame(_channels({})) + "\n")
	_clock += SerialRadioLink.HELLO_WAIT_MS + 10
	link.feed(_frame(_channels({})) + "\n")
	_check("link: without a hello the radio is announced after the wait, named from its USB product",
		link.device_id >= 0 and JoypadDirectory.joy_name(link.device_id) == "OpenTX Jumper T-Pro Joystick")
	link.stop()
	_check("link: stop ends the device", link.device_id < 0)
	link.queue_free()
