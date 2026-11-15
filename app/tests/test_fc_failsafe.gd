# FC-2: failsafe. The modelled radio link (sim/rc_link.gd), the flight controller's automatic return home and the
# pilot's takeover (sim/fixed_wing_fc.gd), the OSD's failsafe and home-reserve warnings, the preferences, and a
# closed-loop flight: the radio link is lost while the pilot holds full roll; the airplane ignores it and comes home.
# Run: godot --headless --path . --script res://tests/test_fc_failsafe.gd
extends SceneTree

const FlightSession := preload("res://sim/flight_session.gd")
const Catalog := preload("res://app_state/aircraft_catalog.gd")
const FC := preload("res://sim/fixed_wing_fc.gd")
const RcLink := preload("res://sim/rc_link.gd")
const CameraSettings := preload("res://render/camera/camera_settings.gd")
const DisplayPreferences := preload("res://app_state/display_preferences.gd")
const OsdModel := preload("res://render/overlays/fpv_osd_model.gd")
const RB := preload("res://physics/rigid_body.gd")

var _failures := 0
var _count := 0


func _check(label: String, ok: bool, detail := "") -> void:
	_count += 1
	print(("ok   " if ok else "FAIL ") + label + ("" if ok or detail.is_empty() else "  " + detail))
	if not ok:
		_failures += 1


func _initialize() -> void:
	_rc_link()
	_controller()
	_osd()
	_preferences()
	_flight()
	print("%d checks, %d failures" % [_count, _failures])
	quit(1 if _failures > 0 else 0)


## Feeds `seconds` of a constant path at 10 Hz; returns the link.
func _run(link: RefCounted, seconds: float, distance: float, terrain := false) -> RefCounted:
	for i in roundi(seconds / 0.1):
		link.update(distance, terrain, 0.0, 0.1)
	return link


func _rc_link() -> void:
	var off := RcLink.new()
	_run(off, 5.0, 50000.0)
	_check("off: a perfect link at any distance", not off.enabled() and off.quality == 1.0 and not off.lost and off.osd_link().is_empty())
	var elrs := RcLink.new()
	elrs.configure("elrs_2g4")
	_run(elrs, 3.0, 1000.0)
	_check("2.4 GHz: clean at 1 km", elrs.quality > 0.99 and not elrs.lost, str(elrs.quality))
	_check("2.4 GHz: half quality near 6 km", absf(RcLink.quality_of(RcLink.margin_db("elrs_2g4", 6000.0, false, 0.0)) - 0.5) < 0.01)
	_run(elrs, 0.5, 14000.0)
	_check("2.4 GHz at 14 km: not yet failsafe within the 1 s delay", not elrs.lost and elrs.quality < RcLink.LOST_QUALITY)
	_run(elrs, 1.0, 14000.0)
	_check("2.4 GHz at 14 km: failsafe after the delay", elrs.lost)
	_check("the OSD figure is the radio's link quality", float(elrs.osd_link().quality_pct) < 15.0)
	_run(elrs, 0.5, 2000.0)
	_check("a returning signal recovers only after its own delay", elrs.lost)
	_run(elrs, 2.0, 2000.0)
	_check("2.4 GHz back at 2 km: recovered", not elrs.lost)
	var blocked_24 := _run(_configured("elrs_2g4"), 3.0, 3000.0, true)
	var blocked_900 := _run(_configured("lr_900"), 3.0, 3000.0, true)
	_check("behind a hill at 3 km: 2.4 GHz is lost, 900 MHz holds", blocked_24.lost and not blocked_900.lost,
		"%.2f / %.2f" % [blocked_24.quality, blocked_900.quality])
	_check("900 MHz: still clean at 15 km in the open", not _run(_configured("lr_900"), 3.0, 15000.0).lost)
	_check("the long-range link reaches past the 20 km field edge", _run(_configured("lr_900"), 3.0, 20000.0).quality > 0.5)


func _configured(mode: String) -> RefCounted:
	var link := RcLink.new()
	link.configure(mode)
	return link


func _controller() -> void:
	var fc := FC.new()
	fc.set_mode("angle")
	_check("a radio-link loss returns home", fc.trigger_rth("rx_loss") and fc.mode == "rth" and fc.failsafe == "rx_loss")
	_check("no mode change while the radio link is lost (switch, M)", not fc.set_mode("manual") and fc.mode == "rth")
	_check("video loss does not replace a radio failsafe", not fc.trigger_rth("video") and fc.failsafe == "rx_loss")
	var s := PackedFloat64Array()
	s.resize(RB.SIZE)
	s[RB.ATT] = 1.0
	s[RB.POS + 2] = -0.2
	var on_ground: Dictionary = fc.step({roll = 1.0, pitch = -1.0, yaw = 1.0, throttle = 1.0}, s, 0.0, 0.01, 1)
	_check("no packets on the ground: centred sticks and idle, whatever the pilot holds", on_ground.roll == 0.0
		and on_ground.pitch == 0.0 and on_ground.yaw == 0.0 and on_ground.throttle == 0.0, str(on_ground))
	fc.link_recovered()
	_check("the link back keeps the return until the pilot acts", fc.failsafe == "" and fc.awaiting_pilot and fc.mode == "rth")
	_check("the mode switch takes over", fc.set_mode("cruise") and fc.mode == "cruise" and not fc.awaiting_pilot)
	fc.trigger_rth("video")
	_check("video loss returns home (the sticks still work)", fc.mode == "rth" and fc.failsafe == "video")
	fc.step({roll = 0.8, pitch = 0.0, yaw = 0.0, throttle = 0.5}, s, 0.0, 0.01, 2)
	_check("a stick past half takes over, back to the mode before", fc.mode == "cruise" and fc.failsafe == "" and not fc.awaiting_pilot)
	fc.trigger_rth("battery")
	fc.reset()
	_check("a restart ends a failsafe and restores the mode", fc.mode == "cruise" and fc.failsafe == "" and not fc.awaiting_pilot)


func _osd() -> void:
	var t := {ground_speed = 20.0, vertical_speed = 0.0, heading_deg = 0.0, pilot_north_m = 1000.0, pilot_east_m = 0.0,
		time_s = 120.0, flight_mode = "rth", failsafe = "rx_loss"}
	var battery := {valid = true, pack_voltage_v = 16.0, cell_avg_v = 4.0, remaining_pct = 50.0, current_a = 10.0,
		used_mah = 1000, used_mah_raw = 1000.0, capacity_mah = 2200.0, alarms = ["lvc"]}
	_check("RX LOSS outranks every battery alarm", OsdModel.values(t, battery).warning.text == "RX LOSS - RTH"
		and OsdModel.values(t, battery).warning.severity == OsdModel.CRITICAL)
	t.failsafe = "video"
	_check("a critical battery alarm outranks a video-loss return", OsdModel.values(t, battery).warning.text == "LOW VOLTAGE CUT")
	battery.alarms = []
	_check("video-loss return is shown", OsdModel.values(t, battery).warning.text == "VIDEO LOSS - RTH")
	t.failsafe = ""
	t.fc_awaiting_pilot = true
	_check("after a return: the takeover hint", OsdModel.values(t, battery).warning.text == "RTH - MOVE STICKS")
	t.fc_awaiting_pilot = false
	# 1000 mAh in 120 s = 30 A average; 1000 m at 20 m/s = 50 s → 417 mAh needed, 1200 mAh left: enough.
	var v := OsdModel.values(t, battery)
	_check("home reserve: the charge home from this flight's average current", absf(float(v.home_mah) - 416.7) < 1.0
		and v.warning.is_empty(), str(v.home_mah))
	t.pilot_north_m = 3500.0 # 175 s home → 1458 mAh, more than the 1200 left
	_check("too little charge to get home is a warning", OsdModel.values(t, battery).warning.text == "BATT LOW FOR HOME")
	t.time_s = 10.0
	_check("no home estimate in the first 30 s", is_nan(float(OsdModel.values(t, battery).home_mah)))


func _preferences() -> void:
	_check("failsafe defaults: perfect radio link, no automatic video or battery return",
		CameraSettings.DEFAULTS.camera_fc_rc_link == "off" and not CameraSettings.DEFAULTS.camera_fc_video_rth
		and not CameraSettings.DEFAULTS.camera_fc_battery_rth)
	var bad := CameraSettings.DEFAULTS.duplicate()
	bad.camera_fc_rc_link = "wifi"
	bad.camera_fc_video_rth = "yes"
	_check("unknown link and non-boolean returns are rejected", CameraSettings.errors(bad).size() == 2, str(CameraSettings.errors(bad)))
	_check("saved as fc_rc_link, fc_video_rth, fc_battery_rth", DisplayPreferences.CAMERA_FILE_KEYS.get("camera_fc_rc_link") == "fc_rc_link"
		and DisplayPreferences.CAMERA_FILE_KEYS.get("camera_fc_video_rth") == "fc_video_rth"
		and DisplayPreferences.CAMERA_FILE_KEYS.get("camera_fc_battery_rth") == "fc_battery_rth")


func _flight() -> void:
	var session := FlightSession.new()
	session.setup(Catalog.entry("stik-electric-6s").data)
	root.add_child(session)
	session.input_enabled = false
	session.trim_at(16.0, "level")
	session.set_start_altitude(200.0)
	session.reset()
	session.flight_controller.set_mode("angle")
	var fc: RefCounted = session.flight_controller
	_fly(session, 20.0, 0.0)
	var away := _home_distance(session)
	fc.trigger_rth("rx_loss")
	_fly(session, 120.0, 1.0) # the pilot holds full right roll the whole time: the receiver passes nothing
	var home := _home_distance(session)
	_check("radio lost %.0f m out, full roll held: the Stik comes home and circles 40 m above home" % away, fc.rth_phase == "orbit"
		and home < 1.4 * fc.loiter_radius and absf(-session.sim.state[RB.POS + 2] - (-fc.home[2] + FC.RTH_MIN_HEIGHT)) < 3.0,
		"%s %.0f m h %.1f target %.1f home %s" % [fc.rth_phase, home, -session.sim.state[RB.POS + 2], fc.target_height, str(fc.home)])
	fc.link_recovered()
	_fly(session, 2.0, 0.0)
	_check("link back, sticks centred: still returning", fc.mode == "rth" and fc.awaiting_pilot)
	_fly(session, 1.0, 0.8)
	_check("a roll stick takes over: Angle again", fc.mode == "angle" and not fc.awaiting_pilot)
	session.free()


func _fly(session: Node, seconds: float, roll: float) -> void:
	var sim: Node = session.sim
	for i in roundi(seconds / sim.dt()):
		session.commands = {roll = roll, pitch = 0.0, yaw = 0.0, throttle = session.start.throttle}
		sim.inputs = session._inputs()
		sim.step()


func _home_distance(session: Node) -> float:
	var s: PackedFloat64Array = session.sim.state
	var home: PackedFloat64Array = session.flight_controller.home
	return Vector2(s[RB.POS] - home[0], s[RB.POS + 1] - home[1]).length()
