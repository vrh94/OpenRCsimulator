# Option 7 (2026-11-22): the Kamnik (Duplica) landscape in the Ljubljana basin. Baked grids and photos load and match
# published heights; the pilot stands at the airstrip's threshold 29 on level ground at its real height; the Kamnik
# Alps, Krvavec, Velika planina, Rašica and Šmarna gora are in the ring and in sight (line of sight over the baked
# terrain); the camera far plane reaches the ring's farthest corner; the field validates and flies in its real air.
# Run: godot --headless --path . --audio-driver Dummy --script res://tests/test_kamnik_landscape.gd
extends SceneTree

const Landscape = preload("res://landscapes/kamnik_duplica/landscape.gd")
const Heightfield = preload("res://landscapes/triglav_tamar/heightfield.gd")
const Catalog = preload("res://landscapes/catalog.gd")
const FieldLoader = preload("res://data/field_loader.gd")
const FieldAir = preload("res://physics/field_air.gd")
const TerrainDem = preload("res://physics/terrain_dem.gd")
const Spec = preload("res://spec.gd")
const ROOT := "res://landscapes/kamnik_duplica/"

## Summits as the ring's highest node near each published summit (metres east, north of the pilot; research/kamnik/
## README.md), with the published height. SRTM rounds the sharp limestone tops by up to about 40 m.
const SUMMITS := {
	"Grintovec": [Vector2(-3574.0, 17835.0), 2558.0],
	"Planjava": [Vector2(2385.0, 17744.0), 2394.0],
	"Velika planina": [Vector2(4680.0, 11339.0), 1666.0],
	"Rašica": [Vector2(-5635.0, -5886.0), 641.0],
	"Šmarna gora": [Vector2(-9920.0, -7555.0), 669.0],
}

var failures := 0
var checks := 0
var core: RefCounted
var ring: RefCounted


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, passed: bool, detail: String = "") -> void:
	checks += 1
	print(("ok   " if passed else "FAIL ") + label + ("" if passed or detail.is_empty() else " (%s)" % detail))
	if not passed:
		failures += 1


func _run() -> void:
	core = Heightfield.load_grid(ROOT + "terrain/core.json", Landscape.CORE_ORIGIN)
	ring = Heightfield.load_grid(ROOT + "terrain/ring.json", Landscape.CORE_ORIGIN)
	check("core grid loads and matches its checksum", core.ok(), core.error)
	check("ring grid loads and matches its checksum", ring.ok(), ring.error)
	check("core is 8 x 8 km at 2 m, ring 48 x 48 km at 16 m", core.columns == 4000 and core.spacing == 2.0
		and ring.columns == 3000 and ring.spacing == 16.0)
	if not core.ok() or not ring.ok():
		_finish()
		return
	_catalog_and_field()
	_heights()
	_mountains()
	await _build()
	_finish()


func _catalog_and_field() -> void:
	check("the catalog lists Kamnik after Triglav", Catalog.ids() == ["club_field", "green_paradise", "triglav_tamar", "kamnik_duplica"],
		str(Catalog.ids()))
	var entry := Catalog.entry("kamnik_duplica")
	check("the catalog names its field", entry.get("field_path", "") == Landscape.FIELD_PATH)
	var loaded: Dictionary = FieldLoader.load_from(Landscape.FIELD_PATH)
	check("the Kamnik field validates", loaded.ok, str(loaded.get("errors", [])))
	if not loaded.ok:
		return
	var field: Dictionary = loaded.field
	check("the field's terrain origin is the pilot spot", is_equal_approx(float(field.terrain.origin_east), Landscape.CORE_ORIGIN.x + Landscape.PILOT_CORE.x)
		and is_equal_approx(float(field.terrain.origin_north), Landscape.CORE_ORIGIN.y + Landscape.PILOT_CORE.y))
	# Manual: the airstrip's elevation is 349 m.
	var elevation := FieldAir.elevation_m(field)
	check("the field flies in the air of its real height (349 m, +-3 m)", absf(elevation - 349.0) <= 3.0, str(elevation))
	var far := Catalog.camera_far_m("kamnik_duplica", Spec.CAMERA.far)
	var corner := 0.0
	for x: float in [ring.origin_east, ring.origin_east + (ring.columns - 1) * ring.spacing]:
		for y: float in [ring.origin_north, ring.origin_north + (ring.rows - 1) * ring.spacing]:
			corner = maxf(corner, Vector2(x, y).distance_to(Landscape.PILOT_CORE))
	check("the camera sees to the ring's farthest corner", far >= corner and far > Spec.CAMERA.far, "%.0f vs %.0f" % [far, corner])
	check("other landscapes keep the default far plane", Catalog.camera_far_m("triglav_tamar", Spec.CAMERA.far) == Spec.CAMERA.far
		and Catalog.camera_far_m("club_field", Spec.CAMERA.far) == Spec.CAMERA.far)
	var dem: RefCounted = TerrainDem.load_cached(ROOT + "terrain/core.json", ROOT + "terrain/ring.json",
		float(field.terrain.origin_east), float(field.terrain.origin_north))
	var level := true
	for at: Vector2 in [Vector2(-16.0, -24.0), Vector2(-16.0, 12.0), Vector2(0.0, 0.0), Vector2(12.0, 0.0)]:
		level = level and absf(float(dem.sample(at.x, at.y)[0])) < 0.6
	check("the strip and the pilot spot are level ground (within 0.6 m)", level)


func _heights() -> void:
	var pilot: float = core.height_at(Landscape.PILOT_CORE.x, Landscape.PILOT_CORE.y)
	check("the pilot spot is at 348-353 m", pilot > 348.0 and pilot < 353.0, str(pilot))
	var inside: float = ring.height_at(Landscape.PILOT_CORE.x, Landscape.PILOT_CORE.y)
	check("the ring agrees with the core at the pilot within 2 m", absf(inside - pilot) < 2.0, "%.2f" % inside)
	check("the ring holds the Kamnik Alps above 2400 m", ring.max_m > 2400.0, str(ring.max_m))


func _mountains() -> void:
	for name: String in SUMMITS:
		var at: Vector2 = Landscape.PILOT_CORE + SUMMITS[name][0]
		var height: float = ring.height_at(at.x, at.y)
		check("%s stands at its published height (-45 m .. +15 m)" % name,
			height > float(SUMMITS[name][1]) - 45.0 and height < float(SUMMITS[name][1]) + 15.0, "%.0f m" % height)
	# From the pilot's eyes the nearer summits show; Grintovec's top hides behind the foothills until about 150 m up.
	for name: String in ["Planjava", "Velika planina", "Rašica"]:
		check("from the pilot spot the top of %s is in sight" % name, _top_visible(name, 1.7))
	for name: String in SUMMITS:
		check("200 m above the field the top of %s is in sight" % name, _top_visible(name, 200.0))


## Whether the top 30 m of a summit is in a straight line of sight from `height_m` above the pilot spot.
func _top_visible(name: String, height_m: float) -> bool:
	var from := Vector3(Landscape.PILOT_CORE.x, Landscape.PILOT_CORE.y, _ground(Landscape.PILOT_CORE) + height_m)
	var at: Vector2 = Landscape.PILOT_CORE + SUMMITS[name][0]
	var to := Vector3(at.x, at.y, float(ring.height_at(at.x, at.y)) - 30.0)
	var steps := 3000
	for i in range(1, int(steps * 0.97)):
		var p := from.lerp(to, float(i) / steps)
		if _ground(Vector2(p.x, p.y)) > p.z:
			return false
	return true


func _ground(p: Vector2) -> float:
	return core.height_at(p.x, p.y) if core.contains(p.x, p.y, 4.0) else ring.height_at(p.x, p.y)


func _build() -> void:
	var loaded: Dictionary = FieldLoader.load_from(Landscape.FIELD_PATH)
	var field: Node3D = Landscape.build(loaded.get("field", {}), {})
	root.add_child(field)
	await process_frame
	var view: Node3D = field.get_node_or_null("Terrain")
	check("the landscape builds its terrain view", view != null)
	var ground_ref: float = field.get_meta("terrain_ground_ref_m", NAN)
	check("render height zero is the terrain at the pilot spot",
		absf(ground_ref - core.height_at(Landscape.PILOT_CORE.x, Landscape.PILOT_CORE.y)) < 0.05, str(ground_ref))
	var materials: Array = field.get_meta("lighting_materials", [])
	var terrain := materials[0] as ShaderMaterial if not materials.is_empty() else null
	check("the terrain colours the ring from the satellite photo", terrain != null and bool(terrain.get_shader_parameter("ring_photo_enabled"))
		and terrain.get_shader_parameter("ring_photo_origin") == Vector2(-20000.0, -20000.0)
		and float(terrain.get_shader_parameter("ring_photo_size_m")) == 48000.0)
	check("the surveyed core photo fades into it at the core edge", terrain != null and bool(terrain.get_shader_parameter("photo_enabled"))
		and float(terrain.get_shader_parameter("core_photo_fade_m")) == Landscape.CORE_PHOTO_FADE_M)
	check("terrain, two tree and the building materials are registered for lighting", materials.size() == 4, str(materials.size()))
	var trees_header: Variant = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "vegetation/trees.json"))
	var buildings_header: Variant = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "buildings/buildings.json"))
	check("every baked tree is instanced", trees_header is Dictionary and int(field.get_meta("trees_count", -1)) == int(trees_header.count))
	check("every baked building record is meshed", buildings_header is Dictionary
		and int(field.get_meta("buildings_count", -1)) == int(buildings_header.count))
	var obstacles: Dictionary = Catalog.collision_world("kamnik_duplica", loaded.get("field", {}))
	check("the trees and buildings near the pilot are solid", obstacles.get("ok", false) and not (obstacles.world as Dictionary).is_empty(),
		str(obstacles.get("errors", [])))
	field.free()
	await process_frame


func _finish() -> void:
	print("kamnik landscape: %d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)
