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
## Lens defaults (FPV-2 makes them settings): a horizontal FOV typical of a fixed-wing FPV camera and a small uptilt.
const DEFAULT_HFOV_DEG := 110.0
const DEFAULT_TILT_DEG := 5.0
const HFOV_MIN_DEG := 60.0
const HFOV_MAX_DEG := 150.0
const TILT_MIN_DEG := -10.0
const TILT_MAX_DEG := 30.0

## Mount in the model frame (root's local axes: −z nose, +y up, +x right); valid only when `configured`.
var mount := Vector3.ZERO
var mount_source := ""
var configured := false
var hfov_deg := DEFAULT_HFOV_DEG
var tilt_deg := DEFAULT_TILT_DEG


## Installs a mount (model frame). source: "declared" (aircraft data) or "estimated" (derive_mount()).
func configure(model_mount: Vector3, source: String) -> void:
	mount = model_mount
	mount_source = source
	configured = model_mount.is_finite()


func clear() -> void:
	mount = Vector3.ZERO
	mount_source = ""
	configured = false


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
## views (fov vertical, deg).
func placement(airplane: Transform3D, body: Basis, aspect: float) -> Dictionary:
	var b := body.orthonormalized()
	var tilted := b * Basis(Vector3.RIGHT, deg_to_rad(tilt_deg))
	return { position = airplane * mount, basis = tilted, fov = vertical_fov_deg(hfov_deg, aspect) }


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
