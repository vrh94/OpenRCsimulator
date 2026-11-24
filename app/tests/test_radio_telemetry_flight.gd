# Radio telemetry from a real fixed-wing flight (main.tscn), with and without overlays: the classic HUD (overlays off)
# must send the same flight values as the overlay HUD, and nothing is built while no radio is connected over serial.
# Run: python3 tools/godot/run_checked.py --timeout 200 -- "$(app/get-godot.sh)" --headless --path app --script res://tests/test_radio_telemetry_flight.gd
extends SceneTree

const RadioTelemetry := preload("res://sim/radio_telemetry.gd")

var _failures := 0


func _check(label: String, ok: bool, detail := "") -> void:
	if ok:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL %s %s" % [label, detail])


func _initialize() -> void:
	_run()


func _flight(overlays: bool, listening: bool, args := PackedStringArray()) -> Dictionary:
	RadioTelemetry.clear()
	RadioTelemetry.listening = listening
	var flight: Node = load("res://main.tscn").instantiate()
	flight.user_args = args
	flight.overlays_enabled = overlays
	flight.overlay_settings = { preset = "full", units = "metric" }
	root.add_child(flight)
	for i in 40:
		await process_frame
	var values := RadioTelemetry.current(Time.get_ticks_msec())
	flight.queue_free()
	await process_frame
	RadioTelemetry.listening = false
	return values


func _flying(v: Dictionary) -> bool:
	for key in ["alt", "gs", "aspd", "hdg", "pitch", "roll", "dist", "home_dir", "time", "thr"]:
		if not is_finite(float(v.get(key, NAN))):
			return false
	return str(v.get("mode", "")) != "" and str(v.get("aircraft", "")) != ""


func _run() -> void:
	await process_frame
	var hud := await _flight(false, true)
	_check("classic HUD (no overlays): attitude, speeds, home, mode, time and throttle are sent", _flying(hud), str(hud))
	var overlay := await _flight(true, true)
	_check("overlay HUD: the same values are sent", _flying(overlay), str(overlay))
	_check("both HUDs agree on the aircraft", hud.get("aircraft", "") == overlay.get("aircraft", "?"))
	var nobody := await _flight(false, false)
	_check("classic HUD with no serial radio: nothing is built", nobody.is_empty(), str(nobody))
	var electric := await _flight(false, true, PackedStringArray(["--electric-demo=4s-battery"]))
	_check("classic HUD, electric aircraft: battery volts and used mAh are sent",
		is_finite(float(electric.get("volt", NAN))) and is_finite(float(electric.get("mah", NAN))), str(electric))
	print("all radio telemetry flight checks passed" if _failures == 0 else "%d radio telemetry flight check(s) failed" % _failures)
	quit(1 if _failures > 0 else 0)
