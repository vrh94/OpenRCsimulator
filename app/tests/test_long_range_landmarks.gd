# FC-4 (14b): long-range FPV landmarks (render/landscape_upgrade/long_range.gd, data/scenery/long_range.json) and the
# ground's field patchwork following the FPV camera (Atmosphere.set_fields_from_camera, ground.gdshader).
# Run: godot --headless --path . --script res://tests/test_long_range_landmarks.gd
extends SceneTree

const LongRange := preload("res://render/landscape_upgrade/long_range.gd")
const FieldBuilder := preload("res://render/field.gd")
const FieldLoader := preload("res://data/field_loader.gd")
const Atmosphere := preload("res://render/atmosphere.gd")
const LightingConfig := preload("res://environment/time_of_day_config.gd")
const Lighting := preload("res://render/time_of_day_lighting.gd")

## The visual mountains (render/landscape_upgrade/ridges.gd): north 1.6–8.6 km, east ±6.5 km.
const RIDGES := Rect2(1600.0, -6500.0, 7000.0, 13000.0)

var _failures := 0
var _count := 0


func _check(label: String, ok: bool, detail := "") -> void:
	_count += 1
	print(("ok   " if ok else "FAIL ") + label + ("" if ok or detail.is_empty() else "  " + detail))
	if not ok:
		_failures += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_generator()
	var data := LongRange.layout()
	_check("the committed layout loads", not data.is_empty())
	if not data.is_empty():
		_layout(data)
		_build(data)
	_field()
	print("%d checks, %d failures" % [_count, _failures])
	quit(1 if _failures > 0 else 0)


func _generator() -> void:
	var tool := ProjectSettings.globalize_path("res://").path_join("../tools/scenery/long_range.py").simplify_path()
	var out: Array = []
	var code := OS.execute("python3", [tool, "--check"], out, true)
	_check("data/scenery/long_range.json is what tools/scenery/long_range.py writes", code == 0, str(out))


func _layout(data: Dictionary) -> void:
	var off_ground := 0
	var in_ridges := 0
	var points: Array[Vector2] = []
	for p: Array in data.road.points:
		points.append(Vector2(float(p[0]), float(p[1])))
	for cluster: Dictionary in data.clusters:
		for item: Dictionary in cluster.items:
			points.append(Vector2(float(item.north), float(item.east)))
	for p: Vector2 in points:
		var r := p.length()
		off_ground += 1 if r < 6000.0 or r > 19000.0 else 0
		in_ridges += 1 if RIDGES.has_point(p) else 0
	_check("everything stands on the flat ground 6–19 km out (past the horizon relief, inside the ground)", off_ground == 0)
	_check("nothing stands inside the visual mountains", in_ridges == 0)
	var kinds := {}
	for cluster: Dictionary in data.clusters:
		for item: Dictionary in cluster.items:
			kinds[item.prefab] = int(kinds.get(item.prefab, 0)) + 1
	_check("towns with churches, farmsteads and wind farms", int(kinds.get("church", 0)) == 3
		and int(kinds.get("village_house", 0)) >= 50 and int(kinds.get("barn", 0)) == 2 and int(kinds.get("turbine", 0)) == 11,
		str(kinds))
	# The ring road encloses the field: its winding number round the origin is ±1, so a flight out on any bearing crosses it.
	var road: Array = data.road.points
	var winding := 0.0
	for i in road.size() - 1:
		var a := Vector2(float(road[i][0]), float(road[i][1]))
		var b := Vector2(float(road[i + 1][0]), float(road[i + 1][1]))
		winding += a.angle_to(b)
	var closed := Vector2(float(road[0][0]), float(road[0][1])).distance_to(Vector2(float(road[-1][0]), float(road[-1][1]))) < 1.0
	_check("the ring road is closed round the field: every bearing out crosses it", closed and absf(absf(winding) - TAU) < 0.01,
		"winding %.3f rad" % winding)
	var nearest := INF
	var farthest := 0.0
	for p: Array in road:
		var r := Vector2(float(p[0]), float(p[1])).length()
		nearest = minf(nearest, r)
		farthest = maxf(farthest, r)
	_check("the road runs between 6.5 and 17 km out", nearest >= 6500.0 and farthest <= 17000.0, "%.0f…%.0f m" % [nearest, farthest])
	# Each town and farm is on the road (within 600 m), so following the road leads to it.
	var off_road := []
	for cluster: Dictionary in data.clusters:
		if str(cluster.id).ends_with("wind-farm"):
			continue
		var c := Vector2.ZERO
		for item: Dictionary in cluster.items:
			c += Vector2(float(item.north), float(item.east))
		c /= float((cluster.items as Array).size())
		var d := INF
		for i in road.size() - 1:
			d = minf(d, Geometry2D.get_closest_point_to_segment(c, Vector2(float(road[i][0]), float(road[i][1])),
				Vector2(float(road[i + 1][0]), float(road[i + 1][1]))).distance_to(c))
		if d > 600.0:
			off_road.append(cluster.id)
	_check("every town and farm lies on the road", off_road.is_empty(), str(off_road))


func _build(data: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var node := LongRange.build()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var stats: Dictionary = node.get_meta("stats", {})
	var expected := 0
	for cluster: Dictionary in data.clusters:
		expected += (cluster.items as Array).size()
	_check("one mesh per cluster plus the road, within the %d-mesh budget" % LongRange.MAX_MESHES,
		int(stats.get("meshes", 0)) == (data.clusters as Array).size() + 1 and int(stats.meshes) <= LongRange.MAX_MESHES, str(stats))
	_check("within the %d-triangle budget" % LongRange.MAX_TRIANGLES, int(stats.get("triangles", 0)) > 0
		and int(stats.triangles) <= LongRange.MAX_TRIANGLES, str(stats.get("triangles")))
	_check("every landmark is built", int(stats.get("items", 0)) == expected)
	var static_only := not node.is_processing()
	for child: Node in node.get_children():
		static_only = static_only and child is MeshInstance3D and child.get_child_count() == 0 \
			and (child as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_check("static meshes only: no motion nodes, no shadow casting", static_only)
	_check("built in a single short stage (%.1f ms)" % ms, ms < 400.0)
	var far := node.get_node_or_null("Landmarks_north-village") as MeshInstance3D
	_check("clusters are positioned at their centre (float precision 15 km out)", far != null
		and far.position.length() > 14000.0 and far.mesh.get_aabb().size.length() < 1000.0)
	print("     long-range stats: ", stats)
	node.free()


func _field() -> void:
	var previous := {}
	for key: String in ["OPENRC_SCENERY", "OPENRC_SCENERY_FILE", "OPENRC_LANDSCAPE_UPGRADE"]:
		previous[key] = OS.get_environment(key)
	OS.set_environment("OPENRC_SCENERY", "on")
	OS.set_environment("OPENRC_SCENERY_FILE", "")
	OS.set_environment("OPENRC_LANDSCAPE_UPGRADE", "on")
	var field: Dictionary = FieldLoader.load_from().field
	var noon := Lighting.snapshot(LightingConfig.preset(LightingConfig.defaults(), "noon").config)
	var built := FieldBuilder.build(field, noon)
	root.add_child(built)
	_check("the default field attaches the long-range landmarks", built.get_node_or_null("LongRangeLandmarks") != null)
	var grounds: Array = []
	for m: Variant in built.get_meta("lighting_materials", []):
		if m is ShaderMaterial and (m as ShaderMaterial).shader == Atmosphere.GROUND_SHADER:
			grounds.append(m)
	var pinned := not grounds.is_empty()
	for m: ShaderMaterial in grounds:
		pinned = pinned and m.get_shader_parameter("fields_from_camera") != true
	_check("pilot view: the field patchwork stays pinned to the pilot (unchanged)", pinned, str(grounds.size()))
	var set_count := Atmosphere.set_fields_from_camera(built, true)
	var follows := set_count == grounds.size() and set_count > 0
	for m: ShaderMaterial in grounds:
		follows = follows and m.get_shader_parameter("fields_from_camera") == true
	_check("FPV views: the patchwork follows the camera on every ground material", follows, str(set_count))
	Atmosphere.set_fields_from_camera(built, false)
	var back := true
	for m: ShaderMaterial in grounds:
		back = back and m.get_shader_parameter("fields_from_camera") == false
	_check("back to the pilot view: pinned again", back)
	built.free()
	for key: String in previous:
		if str(previous[key]).is_empty():
			OS.unset_environment(key)
		else:
			OS.set_environment(key, previous[key])
