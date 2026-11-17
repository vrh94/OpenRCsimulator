## Presentation-only RC chase, driver's stand and orbit cameras, the circuit overview, and (CAR-VIEW-1) an onboard FPV
## camera on the truck's roof and a bumper camera.
extends RefCounted

const Chase = preload("res://render/camera/chase_view.gd")
const CameraMath = preload("res://render/camera/camera_math.gd")
const OnboardView = preload("res://render/camera/onboard_view.gd")

## Modes: 0 chase, 1 driver's stand, 2 orbit, 3 circuit overview (tracks only), 4 onboard FPV, 5 bumper camera.
const MODE_FPV := 4
const MODE_BUMPER := 5
## CAR-VIEW-1 mounts, estimated from the built model like the airplanes' (onboard_view.gd estimate_at): on the
## centreline, a share of the length behind the front, above the highest surface there by the clearance. The FPV
## camera sits on the tallest part of the body between FPV_STATIONS (cab roof, or on top of a nitro engine's scoop,
## which would otherwise fill the picture); the bumper camera low at the front, straight ahead with a plain lens.
const FPV_STATIONS: Array[float] = [0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55]
const FPV_CLEARANCE_M := 0.04
const BUMPER_STATION_SHARE := 0.12
const BUMPER_CLEARANCE_M := 0.025
const BUMPER_HFOV_DEG := 90.0
const BUMPER_TILT_DEG := -4.0
## Right-drag head-look in the FPV view (deg per pixel) and its limits.
const LOOK_DEG_PER_PX := 0.25
const LOOK_YAW_LIMIT_DEG := 170.0
const LOOK_PITCH_LIMIT_DEG := 80.0

var chase = Chase.new()
var mode := 0
var orbit_yaw := PI + 0.65
var orbit_pitch := 0.28
var distance := 2.0
var pilot_position := Vector3(4.0, 1.6, 2.0)
var track_center := Vector3(0.0, 0.0, -45.0)
## CAR-VIEW-1: the FPV camera follows the pilot's Settings › Camera FPV choices (FOV, tilt, mount, shake); the bumper
## camera is fixed. Both need configure_mounts() before they can be shown.
var onboard = OnboardView.new()
var bumper = OnboardView.new()
## The sprung body's frame in the world for this frame (set by the scene before update(); model axes: −z forward,
## +y up). The onboard mounts ride on it, so the picture rolls and pitches with the body on its suspension.
var vehicle_frame := Transform3D()
var _snap := true

func _init() -> void:
	chase.distance = 2.0
	chase.height = 0.8
	bumper.set_preferences(BUMPER_HFOV_DEG, BUMPER_TILT_DEG, "off")

func reset() -> void:
	chase.reset()
	onboard.snap()
	bumper.snap()
	_snap = true

## Installs both onboard mounts from the built model's triangles (model frame). Returns true when the FPV camera has
## a mount; a model without usable geometry keeps the onboard views out of the cycle.
func configure_mounts(faces: PackedVector3Array) -> bool:
	var fpv := {ok = false}
	for share: float in FPV_STATIONS:
		var candidate: Dictionary = OnboardView.estimate_at(faces, share, FPV_CLEARANCE_M, 0.0)
		if candidate.ok and (not fpv.ok or candidate.position.y > fpv.position.y + 0.005):
			fpv = candidate
	var low: Dictionary = OnboardView.estimate_at(faces, BUMPER_STATION_SHARE, BUMPER_CLEARANCE_M, 0.0)
	onboard.clear()
	bumper.clear()
	if fpv.ok:
		onboard.configure(fpv.position, "estimated")
	if low.ok:
		bumper.configure(low.position, "estimated")
	return onboard.configured

## Whether a mode can be shown now.
func available(index: int, has_track: bool) -> bool:
	match index:
		3: return has_track
		MODE_FPV: return onboard.configured
		MODE_BUMPER: return bumper.configured
	return index >= 0 and index <= 2

## The C cycle: chase, driver's stand, orbit, FPV, bumper, then the circuit overview where there is a circuit.
func cycle_order(has_track: bool) -> Array[int]:
	var order: Array[int] = []
	for index: int in [0, 1, 2, MODE_FPV, MODE_BUMPER, 3]:
		if available(index, has_track):
			order.append(index)
	return order

func next_mode(has_track: bool, step := 1) -> int:
	var order := cycle_order(has_track)
	var at := order.find(mode)
	if at < 0:
		return order[0]
	return order[posmod(at + step, order.size())]

func showing_onboard() -> bool:
	return mode == MODE_FPV or mode == MODE_BUMPER

func drag(relative: Vector2) -> void:
	if mode == MODE_FPV:
		# Head-look, as in the airplanes' onboard view (yaw right, pitch up; deg).
		onboard.look = Vector3(clampf(onboard.look.x + relative.x * LOOK_DEG_PER_PX, -LOOK_YAW_LIMIT_DEG, LOOK_YAW_LIMIT_DEG),
			clampf(onboard.look.y - relative.y * LOOK_DEG_PER_PX, -LOOK_PITCH_LIMIT_DEG, LOOK_PITCH_LIMIT_DEG), 0.0)
		return
	orbit_yaw -= relative.x * 0.006
	orbit_pitch = clampf(orbit_pitch + relative.y * 0.005, 0.08, 1.3)

## Wheel: chase/orbit distance; in the FPV view one 10° lens step (factor < 1 zooms in, as for the other views).
func zoom(factor: float) -> void:
	if mode == MODE_FPV:
		onboard.adjust_fov(-1 if factor < 1.0 else 1)
		return
	distance = clampf(distance * factor, 0.9, 8.0)
	chase.distance = distance
	chase.height = distance * 0.4

## Backspace in the FPV view: look ahead again with the chosen lens.
func reset_look() -> void:
	onboard.look = Vector3.ZERO
	onboard.reset_lens()

func update(camera: Camera3D, target: Vector3, body: Basis, dt: float, menu: bool, terrain: Callable) -> void:
	var position: Vector3
	var view = onboard if mode == MODE_FPV else bumper
	if mode == 3:
		position = track_center + Vector3(-6.0, 27.0, 26.0)
		camera.global_position = position
		camera.global_basis = CameraMath.look_basis(position, track_center + Vector3(4.0 if menu else 0.0, 0.0, 4.0))
		camera.fov = 48.0
	elif showing_onboard() and not menu and view.configured:
		var size := camera.get_viewport().get_visible_rect().size if camera.is_inside_tree() else Vector2(16.0, 9.0)
		var aspect := size.x / size.y if size.y > 0.0 else 16.0 / 9.0
		var placed: Dictionary = view.update(vehicle_frame, vehicle_frame.basis.orthonormalized(), aspect, dt, false)
		camera.global_position = placed.position
		camera.global_basis = placed.basis
		camera.fov = placed.fov
	elif mode == 0 and not menu:
		var pose: Dictionary = chase.update(target, body, dt, false, terrain)
		camera.global_position = pose.position
		camera.global_basis = pose.basis
		camera.fov = 54.0
	elif mode == 1 and not menu:
		position = pilot_position
		camera.global_position = position
		camera.global_basis = CameraMath.look_basis(position, target)
		camera.fov = clampf(rad_to_deg(2.0 * atan(2.0 / maxf(position.distance_to(target), 0.1))), 18.0, 65.0)
	else:
		var radius := distance if not menu else 1.65
		position = target + Vector3(sin(orbit_yaw) * cos(orbit_pitch), sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch)) * radius
		position.y = maxf(position.y, float(terrain.call(position.x, position.z)) + 0.12)
		camera.global_position = position
		var look_target := target + Vector3(0, 0.01, 0)
		# Shift the truck left while the garage panel occupies the right third.
		if menu:
			look_target += Vector3.UP.cross(position - target).normalized() * 0.28
		camera.global_basis = CameraMath.look_basis(position, look_target)
		camera.fov = 46.0
	_snap = false
