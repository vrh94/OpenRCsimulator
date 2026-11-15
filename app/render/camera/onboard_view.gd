# CAM-11 / FPV-1: the onboard (FPV) view of a fixed-wing aircraft (docs/plans/camera-views.md §5.3). A rigid camera on
# the airframe: it follows the drawn pose exactly (full roll, no smoothing or lag), tilted up about the body's right
# axis. Until an aircraft declares a camera mount (CAM-13), derive_mount() estimates one at the nose, on top of the
# fuselage, from the built model's meshes; the result is labelled "estimated". Presentation only: it reads the root
# transform and basis main.gd draws the aircraft with and never touches the session.
extends RefCounted

## Mount estimate: this share of the model length aft of the foremost non-propeller geometry, on the centreline,
## MOUNT_CLEARANCE_M above the highest surface a vertical line through that point meets. 6 % of the length puts the
## lens just behind a spinner or a pusher nose cone. When the line meets nothing (an open frame), nearby lines within
## STATION_SHARE of the length and CENTRE_SHARE of the span are tried.
const NOSE_SETBACK_SHARE := 0.06
const STATION_SHARE := 0.05
const CENTRE_SHARE := 0.05
const MOUNT_CLEARANCE_M := 0.02
const PROBE_STEPS := 4
## Nodes whose meshes never define the nose: spinning discs and their blur.
const EXCLUDED_NAME_PARTS := ["propeller", "prop_blur", "rotor", "blur"]
## FPV-2 lens: a horizontal FOV typical of a fixed-wing FPV camera and a small uptilt by default. The settings offer
## FOVS and TILTS; in flight −/= step the FOV and Shift+[ / Shift+] the tilt within the same limits, and Backspace
## returns to the chosen settings.
const DEFAULT_HFOV_DEG := 110.0
const DEFAULT_TILT_DEG := 5.0
const FOVS: Array[int] = [70, 80, 90, 100, 110, 120, 130, 140, 150]
const TILTS: Array[int] = [-10, -5, 0, 5, 10, 15, 20, 25, 30]
const HFOV_MIN_DEG := 70.0
const HFOV_MAX_DEG := 150.0
const HFOV_STEP_DEG := 10.0
const TILT_MIN_DEG := -10.0
const TILT_MAX_DEG := 30.0
const TILT_STEP_DEG := 5.0
## FPV-2 mount smoothing: a soft (vibration-damped) mount lets the lens attitude trail the airframe by this half-life
## (s); "off" is the rigid mount. Position always stays on the mount, so the lens never leaves the airframe.
const SMOOTHING := { off = 0.0, light = 0.03, medium = 0.08 }
const DEFAULT_SMOOTHING := "off"
## FPV-4 camera vibration (presentation only, never fed back): a deterministic function of the presentation clock,
## the commanded throttle and the airspeed. Motor/propeller buzz: MOTOR_DEG per axis at full throttle, value noise at
## MOTOR_HZ; a soft mount passes only MOUNT_PASS of it. Airflow buffeting: AIR_DEG per axis at AIR_REF_MPS, growing
## with dynamic pressure (V²) up to AIR_CAP times, value noise at AIR_HZ. Amplitudes are presentation choices, not
## measurements. SHAKE scales both by the pilot's setting.
const MOTOR_DEG := Vector3(0.12, 0.08, 0.12) # pitch, yaw, roll
const MOTOR_HZ := 23.0
const AIR_DEG := Vector3(0.35, 0.2, 0.35)
const AIR_HZ := 2.7
const AIR_REF_MPS := 30.0
const AIR_CAP := 4.0
const MOUNT_PASS := { off = 1.0, light = 0.5, medium = 0.3 }
const SHAKE := { off = 0.0, low = 0.5, medium = 1.0, high = 2.0 }
const DEFAULT_SHAKE := "off"

## Mount in the model frame (root's local axes: −z nose, +y up, +x right); valid only when `configured`.
var mount := Vector3.ZERO
var mount_source := ""
var configured := false
var hfov_deg := DEFAULT_HFOV_DEG
var tilt_deg := DEFAULT_TILT_DEG
## The pilot's settings, which Backspace restores after in-flight steps.
var preferred_hfov_deg := DEFAULT_HFOV_DEG
var preferred_tilt_deg := DEFAULT_TILT_DEG
var smoothing := DEFAULT_SMOOTHING
## FPV-4: vibration setting and this frame's inputs (set by the route before the rig's update).
var shake := DEFAULT_SHAKE
var vibration_clock_s := 0.0
var vibration_throttle := 0.0
var vibration_airspeed := 0.0
## FPV-5: where the lens looks from the mount's straight ahead (yaw right, pitch up, roll clockwise; deg), from the
## rig's FpvHead (mouse head-look, head tracking, servo gimbal).
var look := Vector3.ZERO
var _attitude := Quaternion.IDENTITY # the smoothed lens attitude
var _primed := false


## Installs a mount (model frame). source: "declared" (aircraft data) or "estimated" (derive_mount()).
func configure(model_mount: Vector3, source: String) -> void:
	mount = model_mount
	mount_source = source
	configured = model_mount.is_finite()


func clear() -> void:
	mount = Vector3.ZERO
	mount_source = ""
	configured = false
	_primed = false


## The pilot's lens settings: they apply at once and become what Backspace restores.
func set_preferences(hfov: float, tilt: float, smoothing_mode: String) -> void:
	preferred_hfov_deg = clampf(hfov, HFOV_MIN_DEG, HFOV_MAX_DEG)
	preferred_tilt_deg = clampf(tilt, TILT_MIN_DEG, TILT_MAX_DEG)
	hfov_deg = preferred_hfov_deg
	tilt_deg = preferred_tilt_deg
	set_smoothing(smoothing_mode)


func set_shake(mode: String) -> void:
	if SHAKE.has(mode):
		shake = mode


## FPV-4: this frame's vibration inputs: presentation clock (s), commanded throttle (0…1), airspeed (m/s).
func set_vibration_inputs(clock_s: float, throttle: float, airspeed: float) -> void:
	vibration_clock_s = clock_s
	vibration_throttle = throttle
	vibration_airspeed = airspeed


func set_smoothing(mode: String) -> void:
	if SMOOTHING.has(mode) and mode != smoothing:
		smoothing = mode
		_primed = false


## In-flight steps; each returns true when the value changed.
func adjust_fov(steps: int) -> bool:
	var next := clampf(hfov_deg + HFOV_STEP_DEG * steps, HFOV_MIN_DEG, HFOV_MAX_DEG)
	var changed := next != hfov_deg
	hfov_deg = next
	return changed


func adjust_tilt(steps: int) -> bool:
	var next := clampf(tilt_deg + TILT_STEP_DEG * steps, TILT_MIN_DEG, TILT_MAX_DEG)
	var changed := next != tilt_deg
	tilt_deg = next
	return changed


## Backspace: back to the chosen settings. Returns true when anything changed.
func reset_lens() -> bool:
	var changed := hfov_deg != preferred_hfov_deg or tilt_deg != preferred_tilt_deg
	hfov_deg = preferred_hfov_deg
	tilt_deg = preferred_tilt_deg
	return changed


## The next update() starts settled on the mount (view change, restart, teleport).
func snap() -> void:
	_primed = false


## Estimates a nose mount from the meshes under `root`, in root's local frame. Returns {ok, position, source,
## nose_z, length}; ok is false when the model has no usable geometry.
static func derive_mount(root: Node3D) -> Dictionary:
	var faces := PackedVector3Array()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or _excluded(root, mi):
			continue
		var to_root := _relative(root, mi)
		for p in mi.mesh.get_faces():
			faces.append(to_root * p)
	return estimate_from_faces(faces)


## The estimate on a triangle list (model frame, three vertices per triangle), so it can be tested without meshes.
static func estimate_from_faces(faces: PackedVector3Array) -> Dictionary:
	var count := faces.size() - faces.size() % 3
	if count == 0:
		return { ok = false, position = Vector3.INF, source = "estimated", nose_z = NAN, length = NAN }
	var lo := faces[0]
	var hi := faces[0]
	for i in count:
		lo = lo.min(faces[i])
		hi = hi.max(faces[i])
	var length := hi.z - lo.z
	if length <= 0.0:
		return { ok = false, position = Vector3.INF, source = "estimated", nose_z = lo.z, length = length }
	var station := lo.z + NOSE_SETBACK_SHARE * length
	var centre_x := 0.5 * (lo.x + hi.x)
	var x := centre_x
	var z := station
	var top := surface_top(faces, x, z)
	if not is_finite(top):
		# Nothing on the centreline at the station: try nearby lines, nearest first.
		var half_band := STATION_SHARE * length
		var half_width := maxf(CENTRE_SHARE * (hi.x - lo.x), 0.02)
		for k in range(1, PROBE_STEPS + 1):
			var f := float(k) / PROBE_STEPS
			for offset: Vector2 in [Vector2(0, f), Vector2(0, -f), Vector2(f, 0), Vector2(-f, 0)]:
				var probe := surface_top(faces, centre_x + offset.x * half_width, station + offset.y * half_band)
				if is_finite(probe) and probe > top:
					top = probe
					x = centre_x + offset.x * half_width
					z = station + offset.y * half_band
			if is_finite(top):
				break
	if not is_finite(top):
		return { ok = false, position = Vector3.INF, source = "estimated", nose_z = lo.z, length = length }
	return { ok = true, position = Vector3(x, top + MOUNT_CLEARANCE_M, z), source = "estimated",
		nose_z = lo.z, length = length }


## Height of the highest triangle a vertical line through (x, z) meets, or -INF.
static func surface_top(faces: PackedVector3Array, x: float, z: float) -> float:
	var top := -INF
	var i := 0
	var count := faces.size() - faces.size() % 3
	while i < count:
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		i += 3
		# Barycentric coordinates of (x, z) in the triangle's x-z projection.
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 1e-12:
			continue # edge-on to the vertical: its neighbours carry the surface
		var u := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d
		var v := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d
		var w := 1.0 - u - v
		if u < -1e-9 or v < -1e-9 or w < -1e-9:
			continue
		top = maxf(top, u * a.y + v * b.y + w * c.y)
	return top


## The camera's placement for one drawn pose. airplane: the model root transform (scale included); body: the
## aircraft's basis (nose −z); aspect: width / height of the picture. Returns {position, basis, fov} like the other
## views (fov vertical, deg). The lens turns by `look` (FPV-5: yaw right, pitch up, roll clockwise; deg) like a
## pan-tilt gimbal: pan about the airframe's up axis, then tilt (the mount's uptilt plus the look's pitch), then roll.
func placement(airplane: Transform3D, body: Basis, aspect: float) -> Dictionary:
	return { position = airplane * mount, basis = aimed(body.orthonormalized()), fov = vertical_fov_deg(hfov_deg, aspect) }


## The lens basis on an airframe attitude, with the uptilt and the look.
func aimed(airframe: Basis) -> Basis:
	var pitch := clampf(tilt_deg + look.y, -90.0, 90.0)
	var out := airframe
	if look.x != 0.0:
		out = out * Basis(Vector3.UP, deg_to_rad(-look.x))
	out = out * Basis(Vector3.RIGHT, deg_to_rad(pitch))
	if look.z != 0.0:
		out = out * Basis(Vector3.FORWARD, deg_to_rad(look.z))
	return out


## The placement for this frame with the mount's smoothing: rigid when off; otherwise the airframe attitude the lens
## sees follows the rigid one with the mode's half-life (frame-rate independent), and holds while paused. The look is
## applied after the smoothing, so head-look and the gimbal never lag through the soft mount.
func update(airplane: Transform3D, body: Basis, aspect: float, dt: float, paused: bool) -> Dictionary:
	var placed := placement(airplane, body, aspect)
	var half_life: float = SMOOTHING.get(smoothing, 0.0)
	var rigid := Quaternion(body.orthonormalized())
	if half_life <= 0.0 or not _primed:
		_attitude = rigid
		_primed = true
	elif not paused and dt > 0.0:
		var k := 1.0 - pow(2.0, -dt / half_life)
		_attitude = _attitude.slerp(rigid, k).normalized()
	if half_life > 0.0:
		placed.basis = aimed(Basis(_attitude))
	var jitter := vibration_deg(vibration_clock_s, vibration_throttle, vibration_airspeed, shake, smoothing)
	if jitter != Vector3.ZERO:
		# Lens-local pitch (about x), yaw (about y) and roll (about the view axis z).
		placed.basis = (placed.basis as Basis) * Basis.from_euler(Vector3(deg_to_rad(jitter.x), deg_to_rad(jitter.y),
			deg_to_rad(jitter.z)))
	return placed


## FPV-4: the lens jitter (deg: pitch, yaw, roll) at presentation time `clock_s`. Pure and deterministic.
static func vibration_deg(clock_s: float, throttle: float, airspeed: float, shake_mode: String, mount_mode: String) -> Vector3:
	var gain: float = SHAKE.get(shake_mode, 0.0)
	if gain <= 0.0 or not is_finite(clock_s):
		return Vector3.ZERO
	var motor := clampf(throttle, 0.0, 1.0) * float(MOUNT_PASS.get(mount_mode, 1.0))
	var q := airspeed / AIR_REF_MPS if is_finite(airspeed) else 0.0
	var air := minf(q * q, AIR_CAP)
	var out := Vector3.ZERO
	for axis in 3:
		var buzz := value_noise(clock_s * MOTOR_HZ, 11 + axis) * MOTOR_DEG[axis] * motor
		var gust := value_noise(clock_s * AIR_HZ, 23 + axis) * AIR_DEG[axis] * air
		out[axis] = gain * (buzz + gust)
	return out


## Smooth 1-D value noise in [−1, 1]: hashed lattice values, smoothstep-blended. Deterministic in (x, seed).
static func value_noise(x: float, seed: int) -> float:
	var i := floorf(x)
	var f := x - i
	var a := _hash(i, seed)
	var b := _hash(i + 1.0, seed)
	var t := f * f * (3.0 - 2.0 * f)
	return lerpf(a, b, t)


static func _hash(i: float, seed: int) -> float:
	var h := sin(i * 12.9898 + float(seed) * 78.233) * 43758.5453
	return (h - floorf(h)) * 2.0 - 1.0


## Vertical FOV (deg) giving `hfov` horizontally at `aspect`.
static func vertical_fov_deg(hfov: float, aspect: float) -> float:
	var a := aspect if aspect > 0.0 else 16.0 / 9.0
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(hfov) * 0.5) / a))


static func _excluded(root: Node3D, node: Node) -> bool:
	var n: Node = node
	while n != null and n != root:
		var lower := String(n.name).to_lower()
		for part: String in EXCLUDED_NAME_PARTS:
			if lower.contains(part):
				return true
		n = n.get_parent()
	return false


static func _relative(root: Node3D, node: Node3D) -> Transform3D:
	if node.is_inside_tree() and root.is_inside_tree():
		return root.global_transform.affine_inverse() * node.global_transform
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t
