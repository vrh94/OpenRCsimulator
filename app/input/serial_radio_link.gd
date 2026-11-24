extends Node
## An EdgeTX radio connected over USB in "USB Serial (VCP)" mode, running tools/radio/edgetx/SCRIPTS/TELEMETRY/
## simlnk.lua (SYS > Hardware > USB-VCP = LUA). The radio sends its channel outputs; this link presents them as a
## joypad exactly like EdgeTX's Classic USB joystick, and sends the flight's telemetry back (sim/radio_telemetry.gd).
##
## In USB joystick mode the same radio is an SDL joypad and this link does nothing: EdgeTX's USB port is either a
## joystick or a serial port, never both. So the serial radio takes the joystick's identity (the name, vendor, product
## and SDL GUID the radio reports in joystick mode) and its saved calibration, switch assignments and profile apply
## unchanged. Channel values are scaled the way EdgeTX and SDL scale them for the joystick: CH1-8 are axes 0-7
## (EdgeTX value + 1024, 0..2047, through SDL's -32768..32767 to Godot's -1..1), CH9-16 are buttons 0-7, pressed when
## the channel is above 0.
##
## Only ports whose USB maker is "OpenTX" with ST's VCP ids (0483:5740, EdgeTX's serial mode) are opened, never a
## flight controller's port. A small shell helper (macOS and Linux) finds the port, holds it open in raw mode and
## relays bytes, so the frame loop never blocks. Sticks reach the simulator 20 times a second (EdgeTX runs Lua every
## 50 ms), slower than USB joystick mode.

const JoypadDirectory := preload("res://input/joypad_directory.gd")
const RadioTelemetry := preload("res://sim/radio_telemetry.gd")

const AXES := 8
const BUTTONS := 8
## No channel frame for this long: the radio is gone (switched mode, unplugged, script stopped).
const FRAME_TIMEOUT_MS := 500
## Without a hello line (radio name and EdgeTX version), the device is announced after this long anyway.
const HELLO_WAIT_MS := 2500
const SEND_INTERVAL_MS := 100
const EDGETX_VENDOR := 0x1209
const EDGETX_JOYSTICK_PRODUCT := 0x4F54

## Finds the radio's port, opens it raw and relays: port -> stdout, stdin -> port. Prints "#PORT <path>|<USB product>"
## when a session starts and "#GONE" when it ends; exits when the app does.
const HELPER := """
exec 4<&0
find_port() {
  if [ "$(uname)" = Darwin ]; then
    ioreg -r -c IOUSBHostDevice -l -w0 2>/dev/null | awk '
      /<class IOUSBHostDevice/ { mfr = ""; prod = ""; vid = 0; pid = 0 }
      /"USB Vendor Name" = / { s = $0; sub(/.*"USB Vendor Name" = "/, "", s); sub(/".*/, "", s); mfr = s }
      /"USB Product Name" = / { s = $0; sub(/.*"USB Product Name" = "/, "", s); sub(/".*/, "", s); prod = s }
      /"idVendor" = / { s = $0; sub(/.*"idVendor" = /, "", s); vid = s + 0 }
      /"idProduct" = / { s = $0; sub(/.*"idProduct" = /, "", s); pid = s + 0 }
      /"IOCalloutDevice" = / { s = $0; sub(/.*"IOCalloutDevice" = "/, "", s); sub(/".*/, "", s)
        if (mfr == "OpenTX" && vid == 1155 && pid == 22336) { print s "|" prod; exit } }'
  else
    for d in /sys/class/tty/ttyACM*; do
      [ -e "$d" ] || continue
      u=$(readlink -f "$d/device/..")
      [ "$(cat "$u/idVendor" 2>/dev/null)" = 0483 ] || continue
      [ "$(cat "$u/idProduct" 2>/dev/null)" = 5740 ] || continue
      [ "$(cat "$u/manufacturer" 2>/dev/null)" = OpenTX ] || continue
      echo "/dev/${d##*/}|$(cat "$u/product" 2>/dev/null)"
      return
    done
  fi
}
while kill -0 "$PPID" 2>/dev/null; do
  hit=$(find_port)
  if [ -z "$hit" ]; then sleep 1; continue; fi
  port=${hit%%|*}
  echo "#PORT $hit"
  (
    stty raw -echo clocal <&3 2>/dev/null
    cat <&3 &
    reader=$!
    cat <&4 >&3
    kill "$reader" 2>/dev/null
  ) 3<>"$port"
  echo "#GONE"
  sleep 1
done
"""

signal status_changed

## Time source and output sink, replaceable by tests.
var now_ms: Callable = Time.get_ticks_msec
var write: Callable = _write_pipe
## The flight's telemetry for this moment ({} = none).
var telemetry_source: Callable = func() -> Dictionary: return RadioTelemetry.current(Time.get_ticks_msec())

var port := ""
var usb_product := ""
var radio := ""
var edgetx_version := ""
var device_id := -1
var frames := 0
var bad_lines := 0
var sent_lines := 0

var _pid := -1
var _stdio: FileAccess
var _text := ""
var _channels := PackedInt32Array()
var _first_frame_ms := -1
var _last_frame_ms := -1000000
var _last_send_ms := -1000000
var _send_tick := 0


## Starts the helper (macOS and Linux). Returns false where serial radios are not supported.
func start() -> bool:
	if _pid > 0:
		return true
	if OS.get_name() not in ["macOS", "Linux"]:
		return false
	var child: Dictionary = OS.execute_with_pipe("/bin/sh", PackedStringArray(["-c", HELPER]), false)
	if child.is_empty() or not child.has("stdio"):
		return false
	_pid = int(child.pid)
	_stdio = child.stdio
	return true


func stop() -> void:
	_end_device()
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = -1
	_stdio = null


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	if _stdio != null:
		var available := _stdio.get_length()
		if available > 0:
			feed(_stdio.get_buffer(mini(available, 65536)).get_string_from_ascii())
	tick()


## Bytes from the helper: control lines and radio lines.
func feed(text: String) -> void:
	_text += text
	while true:
		var nl := _text.find("\n")
		if nl < 0:
			break
		var raw_line := _text.substr(0, nl).strip_edges()
		_text = _text.substr(nl + 1)
		if not raw_line.is_empty():
			handle_line(raw_line)
	if _text.length() > 4096:
		_text = ""
		bad_lines += 1


func handle_line(text: String) -> void:
	if text.begins_with("#PORT "):
		var parts := text.substr(6).split("|", true, 1)
		port = parts[0]
		usb_product = parts[1] if parts.size() > 1 else ""
		status_changed.emit()
		return
	if text == "#GONE":
		_end_device()
		port = ""
		status_changed.emit()
		return
	var star := text.rfind("*")
	if star < 0 or star + 3 != text.length() or not text.substr(star + 1).is_valid_hex_number() \
			or RadioTelemetry.checksum(text.substr(0, star)) != text.substr(star + 1).hex_to_int():
		bad_lines += 1
		return
	var payload := text.substr(0, star)
	if payload.begins_with("C") and payload.length() == 1 + 16 * 3:
		var channels := PackedInt32Array()
		for ch in 16:
			var digits := payload.substr(1 + ch * 3, 3)
			if not digits.is_valid_hex_number():
				bad_lines += 1
				return
			channels.append(digits.hex_to_int())
		_on_channels(channels)
	elif payload.begins_with("H,"):
		var fields := payload.split(",")
		radio = fields[1] if fields.size() > 1 else ""
		edgetx_version = fields[2] if fields.size() > 2 else ""
		status_changed.emit()


func _on_channels(channels: PackedInt32Array) -> void:
	var t: int = now_ms.call()
	frames += 1
	_last_frame_ms = t
	if _first_frame_ms < 0:
		_first_frame_ms = t
	if device_id < 0:
		if radio.is_empty() and t - _first_frame_ms < HELLO_WAIT_MS:
			_channels = channels
			return
		_begin_device()
		if device_id < 0:
			return
		_channels = PackedInt32Array()
	for ch in AXES:
		if _channels.is_empty() or _channels[ch] != channels[ch]:
			var motion := InputEventJoypadMotion.new()
			motion.device = device_id
			motion.axis = ch as JoyAxis
			motion.axis_value = axis_value(channels[ch])
			Input.parse_input_event(motion)
	for b in BUTTONS:
		var pressed := channels[AXES + b] > 1024
		if _channels.is_empty() or (_channels[AXES + b] > 1024) != pressed:
			var button := InputEventJoypadButton.new()
			button.device = device_id
			button.button_index = b as JoyButton
			button.pressed = pressed
			Input.parse_input_event(button)
	_channels = channels


## Once per frame: drops a silent radio and sends telemetry 10 times a second while the radio is present.
func tick() -> void:
	var t: int = now_ms.call()
	if device_id >= 0 and t - _last_frame_ms > FRAME_TIMEOUT_MS:
		_end_device()
		status_changed.emit()
	if device_id < 0 or t - _last_send_ms < SEND_INTERVAL_MS:
		return
	_last_send_ms = t
	var values: Dictionary = telemetry_source.call()
	for text in RadioTelemetry.lines(values, _send_tick):
		write.call(text)
		sent_lines += 1
	_send_tick += 1


## Godot's axis value for an EdgeTX joystick channel (0..2047): SDL scales the HID value to -32768..32767 with a
## truncating integer cast, then Godot maps that range to -1..1.
static func axis_value(raw: int) -> float:
	var sdl := int(float(clampi(raw, 0, 2047)) * 65535.0 / 2047.0 - 32768.0)
	return ((sdl + 32768) / 65535.0 - 0.5) * 2.0


## The identity the same radio has as an EdgeTX USB joystick: "OpenTX <USB name> Joystick", pid.codes 1209:4F54,
## and SDL's GUID (USB bus, CRC-16 of the name, vendor, product, EdgeTX version as BCD).
static func joystick_identity(usb_product_name: String, radio_name: String, version: String) -> Dictionary:
	var usb_name := usb_product_name.trim_suffix(" Serial Port").strip_edges()
	if usb_name.is_empty():
		usb_name = "EdgeTX " + (radio_name if not radio_name.is_empty() else "radio")
	var joystick_name := "OpenTX %s Joystick" % usb_name
	var parts := version.split(".")
	var bcd := 0
	if parts.size() >= 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		bcd = (_bcd(int(parts[0])) << 8) | _bcd(int(parts[1]))
	var crc := crc16(joystick_name.to_utf8_buffer())
	var guid := "%s%s%s%s%s%s%s%s" % [_le16(0x0003), _le16(crc), _le16(EDGETX_VENDOR), "0000", _le16(EDGETX_JOYSTICK_PRODUCT),
		"0000", _le16(bcd), "0000"]
	return {name = joystick_name, guid = guid, vendor_id = EDGETX_VENDOR, product_id = EDGETX_JOYSTICK_PRODUCT}


## CRC-16/ARC, as SDL computes it for joystick GUIDs.
static func crc16(data: PackedByteArray) -> int:
	var crc := 0
	for b in data:
		crc ^= b
		for _bit in 8:
			crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
	return crc & 0xFFFF


static func _bcd(v: int) -> int:
	return (floori(v / 10.0) % 10) << 4 | (v % 10)


static func _le16(v: int) -> String:
	return "%02x%02x" % [v & 0xFF, (v >> 8) & 0xFF]


func _begin_device() -> void:
	var id := JoypadDirectory.free_id()
	if id < 0:
		return
	var identity := joystick_identity(usb_product, radio, edgetx_version)
	device_id = id
	_last_send_ms = -1000000
	JoypadDirectory.register(id, identity.name, identity.guid, {
		raw_name = identity.name, vendor_id = identity.vendor_id, product_id = identity.product_id,
		backend = "serial", transport = "usb-cdc", serial_port = port, radio = radio, edgetx_version = edgetx_version,
	})
	status_changed.emit()


func _end_device() -> void:
	if device_id >= 0:
		JoypadDirectory.unregister(device_id, AXES, BUTTONS)
	device_id = -1
	_channels = PackedInt32Array()
	_first_frame_ms = -1


func _write_pipe(text: String) -> void:
	if _stdio != null:
		_stdio.store_string(text)


## One line for menus and diagnostics.
func status() -> String:
	if device_id >= 0:
		return "%s over USB serial (%s): %d frames, %d telemetry lines sent" % [JoypadDirectory.joy_name(device_id), port, frames, sent_lines]
	if not port.is_empty():
		return "EdgeTX serial port %s open, waiting for simlnk.lua" % port
	return "no EdgeTX radio in USB serial mode" if _pid > 0 else "serial radio link off"
