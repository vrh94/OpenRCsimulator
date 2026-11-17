# RADIO-CAR-1 / CAR-VIEW-1: a calibrated radio drives the RC trucks (aileron steers, elevator forward drives, back
# reverses or brakes, buttons follow the Controls bindings), and the trucks have an onboard FPV camera and a bumper
# camera that ride on the body and use the Settings › Camera FPV lens.
# Run: godot --headless --path . --script res://tests/test_car_radio_views.gd
extends SceneTree

const Activity = preload("res://vehicles/ground/ground_scene.gd")
const Registry = preload("res://input/controller_registry.gd")
const Profile = preload("res://input/controller_profile.gd")
const CameraRig = preload("res://vehicles/ground/ground_camera.gd")

class TestActivity extends Activity:
	func _key(_code: Key) -> bool:
		return false

const RADIO := {"id": 13, "name": "RadioMaster TX16S", "guid": "test-car-radio", "kind": "radio", "known": false}
const CAMERA_BUTTON := 2

var checks := 0
var failures := 0
var raw := {0: 0.0, 1: 0.0, 2: -1.0, 3: 0.0}
var profile: Dictionary
var activity: Node3D


func check(ok: bool, label: String, detail := "") -> void:
	checks += 1
	print(("ok   " if ok else "FAIL ") + label + ("" if ok or detail.is_empty() else "  " + detail))
	if not ok:
		failures += 1


func _initialize() -> void:
	_run.call_deferred()


func create(source: RefCounted, vehicle := "mt8-bisonte", prefs := {}) -> Node3D:
	var candidate := TestActivity.new()
	candidate.controller_registry = source
	candidate.vehicle_id = vehicle
	candidate.use_practice_fixture = true
	candidate.enable_audio = false
	candidate.enable_course_visual = false
	candidate.camera_preferences = prefs
	candidate.radio_profile_provider = func(record: Dictionary) -> Dictionary:
		return profile if str(record.get("guid", "")) == RADIO.guid else {}
	candidate.joy_axis_reader = func(_id: int, axis: int) -> float: return float(raw.get(axis, 0.0))
	candidate.joy_button_reader = func(_id: int, _index: int) -> bool: return false
	root.add_child(candidate)
	candidate.set_physics_process(false)
	candidate.set_process(false)
	return candidate


func step(count := 1) -> void:
	for i in count:
		activity._physics_process(1.0 / 240.0)
		activity._process(1.0 / 240.0)


func last_controls() -> PackedFloat64Array:
	var tape: PackedFloat64Array = activity.session.control_tape_snapshot()
	return tape.slice(tape.size() - 4) if tape.size() >= 4 else PackedFloat64Array()


func radio_button(index: int) -> void:
	for pressed: bool in [true, false]:
		var event := InputEventJoypadButton.new()
		event.device = RADIO.id
		event.button_index = index as JoyButton
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
		await process_frame


func _run() -> void:
	profile = Profile.defaults("radio", "radio_custom")
	profile.actions.camera_cycle = {"type": "button", "button": CAMERA_BUTTON}
	var shared := Registry.new()
	shared.update_devices([RADIO])
	shared.select_device("flight", RADIO.id)
	activity = create(shared, "mt8-bisonte", {"camera_fpv_fov": 130, "camera_fpv_lens": "barrel"})
	await process_frame
	await process_frame
	check(activity.startup_error.is_empty(), "truck starts", activity.startup_error)
	if not activity.startup_error.is_empty():
		quit(1)
		return
	await _radio_driving()
	_views()
	activity.free()
	await process_frame
	await _nitro_brakes(shared)
	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _radio_driving() -> void:
	check(activity._controller_device_id == RADIO.id and not activity._controller_requires_selection,
		"the aircraft's calibrated radio is selected for driving when there is no gamepad")
	check(activity.dashboard.controller_choice.item_count == 2 and activity.dashboard.control_hint.text.contains("Aileron")
		and activity.dashboard.control_hint.text.contains("Button %d: camera" % CAMERA_BUTTON),
		"garage lists the radio and its stick and button scheme", activity.dashboard.control_hint.text)
	step(4)
	activity.handle_action("resume")
	check(not activity.session.paused, "centred radio sticks are a neutral sample: Drive starts")
	raw[1] = 0.8 # elevator forward (the default radio pitch channel is inverted)
	raw[0] = 0.5
	step()
	var c := last_controls()
	check(c.size() == 4 and c[0] > 0.7 and c[1] > 0.3 and c[2] == 0.0 and c[3] == 0.0,
		"elevator forward accelerates, aileron right steers right", str(c))
	raw[1] = -0.6
	raw[0] = -0.5
	step()
	c = last_controls()
	check(c[0] > 0.5 and c[1] < -0.3 and c[3] == 1.0, "elevator back reverses, aileron left steers left", str(c))
	raw[1] = 0.02
	raw[0] = 0.0
	step()
	c = last_controls()
	check(c[0] == 0.0 and c[3] == 0.0, "a stick resting near the centre does nothing", str(c))
	var before: int = activity.camera_rig.mode
	await radio_button(CAMERA_BUTTON)
	check(activity.camera_rig.mode != before, "the radio button bound to Cycle camera changes the camera")
	activity.camera_rig.mode = 0
	await radio_button(6) # unbound on this profile (JOY_BUTTON_START on a gamepad)
	check(not activity.dashboard.menu_visible, "an unbound radio button is not read as a gamepad Start")


func _camera_forward() -> Vector3:
	return -activity.camera.global_basis.z


func _views() -> void:
	var rig = activity.camera_rig
	check(rig.onboard.configured and rig.bumper.configured, "both onboard mounts are estimated from the truck model",
		"%s / %s" % [rig.onboard.mount, rig.bumper.mount])
	check(rig.cycle_order(false) == [0, 1, 2, CameraRig.MODE_FPV, CameraRig.MODE_BUMPER], "C cycles chase, stand, orbit, FPV, bumper",
		str(rig.cycle_order(false)))
	check(is_equal_approx(rig.onboard.hfov_deg, 130.0), "the FPV camera uses Settings › Camera FPV field of view")
	activity.handle_action("camera_fpv")
	step()
	var truck: Transform3D = activity.visual.root.global_transform
	var forward: Vector3 = -truck.basis.z.normalized()
	var fpv_position: Vector3 = activity.camera.global_position
	check(rig.mode == CameraRig.MODE_FPV and fpv_position.distance_to(truck.origin) < 0.6
		and (fpv_position - truck.origin).dot(truck.basis.y.normalized()) > 0.0,
		"3: the FPV camera sits on the truck, above its origin", str(fpv_position - truck.origin))
	check(_camera_forward().dot(forward) > 0.9, "the FPV camera looks ahead", str(_camera_forward().dot(forward)))
	check(activity._fpv_lens.evidence().active and activity._fpv_lens.evidence().model == "barrel",
		"the wide-angle FPV lens is on in the FPV view", str(activity._fpv_lens.evidence()))
	raw[1] = 0.9
	step(240)
	truck = activity.visual.root.global_transform
	check(activity.camera.global_position.distance_to(truck.origin) < 0.6, "driving, the FPV camera stays on the truck",
		str(activity.camera.global_position.distance_to(truck.origin)))
	raw[1] = 0.0
	step()
	activity.handle_action("camera_bumper")
	step()
	truck = activity.visual.root.global_transform
	forward = -truck.basis.z.normalized()
	var fpv_now: Vector3 = truck * rig.onboard.mount
	check(rig.mode == CameraRig.MODE_BUMPER and (activity.camera.global_position - fpv_now).dot(forward) > 0.0,
		"Shift+3: the bumper camera is ahead of the FPV camera", str((activity.camera.global_position - fpv_now).dot(forward)))
	check(not activity._fpv_lens.evidence().active, "the bumper camera has no FPV lens pass")
	activity.handle_action("camera_bumper")
	check(rig.mode == 0, "Shift+3 again returns to the chase camera")
	var state_before: PackedFloat64Array = activity.session.state_snapshot()
	activity.handle_action("camera_fpv")
	activity.camera_rig.drag(Vector2(80, 0))
	activity.handle_action("look_reset")
	check(activity.session.state_snapshot() == state_before and rig.onboard.look == Vector3.ZERO,
		"views and head-look are presentation only; Backspace looks ahead again")


func _nitro_brakes(shared: RefCounted) -> void:
	raw = {0: 0.0, 1: 0.0, 2: -1.0, 3: 0.0}
	activity = create(shared, "monster-car-2")
	await process_frame
	await process_frame
	step(4)
	activity.handle_action("resume")
	raw[1] = -0.7
	step()
	var c := last_controls()
	check(c[0] == 0.0 and c[2] > 0.5 and c[3] == 0.0, "nitro truck: elevator back brakes (it has no reverse)", str(c))
	check(activity.dashboard.control_hint.text.contains("back: brake"), "nitro hint names the brake")
	activity.free()
	await process_frame
