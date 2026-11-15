## FC-4 (14b): long-range FPV landmarks, a visual-only backdrop 6.5–16 km out (data/scenery/long_range.json, written by
## tools/scenery/long_range.py). Three towns with churches, two farmsteads and two wind farms on one gravel ring road,
## so an FPV flight past the club's horizon ring has something to navigate by. Like the distant ridges it has no
## collision and no physics; it reuses the club's scenery prefabs, merged into one static mesh per cluster (turbine
## rotors baked in, not spinning) and one road mesh, with no per-frame work.
extends RefCounted

const Frames := preload("res://render/frames.gd")
const MeshKit := preload("res://scenery/mesh_kit.gd")
const Prefabs := preload("res://scenery/prefabs.gd")
const GroundFeatures := preload("res://scenery/ground_features.gd")
const Scenery := preload("res://scenery/scenery.gd")

const PATH := "res://data/scenery/long_range.json"
const FORMAT := "openrc-long-range v1"
## Budgets: the whole layer stays a handful of draw calls and a small share of the club's scenery triangles.
const MAX_MESHES := 10
const MAX_TRIANGLES := 30000
const MIN_DISTANCE_M := 6000.0
const MAX_DISTANCE_M := 19000.0
const PREFABS: Array[String] = ["church", "village_house", "barn", "silo", "farmhouse", "turbine"]


## The validated layout, or {} (with an error) when missing or malformed. Every point must stand on the flat ground
## between MIN_DISTANCE_M and MAX_DISTANCE_M from the field origin.
static func layout(path := PATH) -> Dictionary:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not raw is Dictionary or raw.get("format") != FORMAT or raw.get("physical") != false \
			or not raw.get("clusters") is Array or not raw.get("road") is Dictionary:
		push_error("Long-range landmarks: missing or incompatible layout " + path)
		return {}
	var road: Dictionary = raw.road
	if not road.get("points") is Array or (road.points as Array).size() < 2 \
			or not (road.get("width_m") is float or road.get("width_m") is int):
		push_error("Long-range landmarks: invalid road")
		return {}
	for p: Variant in road.points:
		if not _point_ok(p):
			push_error("Long-range landmarks: road point out of range %s" % str(p))
			return {}
	for cluster: Variant in raw.clusters:
		if not cluster is Dictionary or not cluster.get("items") is Array or (cluster.items as Array).is_empty():
			push_error("Long-range landmarks: invalid cluster")
			return {}
		for item: Variant in cluster.items:
			if not item is Dictionary or str(item.get("prefab", "")) not in PREFABS \
					or not _point_ok([item.get("north"), item.get("east")]):
				push_error("Long-range landmarks: invalid item %s" % str(item))
				return {}
	return raw


static func _point_ok(p: Variant) -> bool:
	if not p is Array or (p as Array).size() < 2:
		return false
	for v: Variant in [p[0], p[1]]:
		if not (v is float or v is int) or not is_finite(float(v)):
			return false
	var r := Vector2(float(p[0]), float(p[1])).length()
	return r >= MIN_DISTANCE_M and r <= MAX_DISTANCE_M


## The backdrop node: one MeshInstance3D per cluster and one for the road; meta "stats" {meshes, triangles, items}.
static func build(theme := "temperate", path := PATH) -> Node3D:
	var root := Node3D.new()
	root.name = "LongRangeLandmarks"
	var data := layout(path)
	if data.is_empty():
		return root
	var material := Scenery.opaque_material()
	var triangles := 0
	var items := 0
	for cluster: Dictionary in data.clusters:
		# Local coordinates round the cluster's centre keep float precision 15 km out.
		var centre := Vector2.ZERO
		for item: Dictionary in cluster.items:
			centre += Vector2(float(item.north), float(item.east))
		centre /= float((cluster.items as Array).size())
		var origin := Frames.ned_to_render([centre.x, centre.y, 0.0])
		var kit := MeshKit.new()
		for item: Dictionary in cluster.items:
			var xf := Transform3D(Basis(Vector3.UP, -deg_to_rad(float(item.get("heading", 0.0)))),
				Frames.ned_to_render([float(item.north), float(item.east), 0.0]) - origin)
			kit.xf = xf
			var moving: Array = Prefabs.build(str(item.prefab), kit, int(item.get("seed", 0)), theme)
			for part: Dictionary in moving: # bake rotors static, each at its own blade angle
				if not part.get("kit") is MeshKit:
					continue
				var part_kit: MeshKit = part.kit
				var spin := Basis(part.axis as Vector3, TAU * float(part.get("phase", 0.0)))
				kit.append_arrays(part_kit.verts, part_kit.norms, part_kit.cols, Transform3D(spin, part.pivot))
			kit.xf = Transform3D.IDENTITY
			items += 1
		triangles += kit.triangle_count()
		root.add_child(_instance("Landmarks_" + str(cluster.get("id", "cluster")), kit, material, origin))
	var road: Dictionary = data.road
	var road_kit := MeshKit.new()
	var poly := PackedVector2Array()
	for p: Array in road.points:
		var r := Frames.ned_to_render([float(p[0]), float(p[1]), 0.0])
		poly.append(Vector2(r.x, r.z))
	GroundFeatures.track(road_kit, poly, float(road.width_m), str(road.get("surface", "gravel")), theme)
	triangles += road_kit.triangle_count()
	root.add_child(_instance("RingRoad", road_kit, material, Vector3.ZERO))
	root.set_meta("stats", {meshes = root.get_child_count(), triangles = triangles, items = items,
		road_points = (road.points as Array).size()})
	return root


static func _instance(name: String, kit: MeshKit, material: Material, origin: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = kit.to_mesh(material)
	mi.position = origin
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
