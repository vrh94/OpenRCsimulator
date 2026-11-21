# TG-03: the Triglav (Planica/Tamar) landscape adapter: baked grids, terrain level of detail, trees and buildings.
# Run: godot --headless --path . --script res://tests/test_triglav_landscape.gd
extends SceneTree

const Landscape = preload("res://landscapes/triglav_tamar/landscape.gd")
const Heightfield = preload("res://landscapes/triglav_tamar/heightfield.gd")
const TerrainView = preload("res://landscapes/triglav_tamar/terrain_view.gd")
const ROOT := "res://landscapes/triglav_tamar/"

var failures := 0
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, passed: bool, detail: String = "") -> void:
	checks += 1
	print(("ok   " if passed else "FAIL ") + label + ("" if passed or detail.is_empty() else " (%s)" % detail))
	if not passed:
		failures += 1


func _run() -> void:
	var core: RefCounted = Heightfield.load_grid(ROOT + "terrain/core.json")
	var ring: RefCounted = Heightfield.load_grid(ROOT + "terrain/ring.json")
	check("core grid loads and matches its checksum", core.ok(), core.error)
	check("ring grid loads and matches its checksum", ring.ok(), ring.error)
	check("core is 4000 x 4000 nodes at 2 m", core.columns == 4000 and core.rows == 4000 and core.spacing == 2.0)
	var missing: RefCounted = Heightfield.load_grid(ROOT + "terrain/missing.json")
	check("a missing grid reports an error instead of loading", not missing.ok() and not missing.error.is_empty())
	# Published heights (docs/plans/triglav-planica-tamar.md): Dom v Tamarju 1108 m, Rateče about 870 m.
	var hut: float = core.height_at(401150.0 - 399000.0, 145956.0 - 144000.0)
	var ratece: float = core.height_at(401174.0 - 399000.0, 151676.0 - 144000.0)
	check("Dom v Tamarju stands at 1108 m (+-2 m)", absf(hut - 1108.0) <= 2.0, str(hut))
	check("Rateče lies at 855-880 m", ratece > 855.0 and ratece < 880.0, str(ratece))
	check("the ring agrees with the core at the hut within 3 m", absf(ring.height_at(2150.0, 1956.0) - hut) < 3.0,
		str(ring.height_at(2150.0, 1956.0)))

	var field: Node3D = Landscape.build({}, {})
	root.add_child(field)
	await process_frame
	var view: Node3D = field.get_node_or_null("Terrain")
	check("the landscape builds its terrain view", view != null)
	var ground_ref: float = field.get_meta("terrain_ground_ref_m", NAN)
	check("render height zero is the terrain at the pilot spot",
		absf(ground_ref - core.height_at(Landscape.PILOT_CORE.x, Landscape.PILOT_CORE.y)) < 0.05, str(ground_ref))
	var materials: Array = field.get_meta("lighting_materials", [])
	check("terrain, two tree and the building materials are registered for lighting", materials.size() == 4,
		str(materials.size()))
	var trees_header: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "vegetation/trees.json"))
	var buildings_header: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "buildings/buildings.json"))
	check("every baked tree is instanced", int(field.get_meta("trees_count", -1)) == int(trees_header.count))
	check("every baked building record is meshed", int(field.get_meta("buildings_count", -1)) == int(buildings_header.count))

	if view != null:
		var at_pilot: int = view.update_for(Vector3(0.0, 1.7, 0.0))
		var leaf_under_pilot := false
		for tile: MeshInstance3D in view.get_children():
			if tile.visible and is_equal_approx(tile.transform.basis.x.x, TerrainView.CORE_LEAF_M):
				var x0 := tile.transform.origin.x
				var z0 := tile.transform.origin.z
				if x0 <= 0.0 and x0 + TerrainView.CORE_LEAF_M >= 0.0 and z0 <= 0.0 and z0 + TerrainView.CORE_LEAF_M >= 0.0:
					leaf_under_pilot = true
		check("a 2 m tile lies under the pilot", leaf_under_pilot)
		check("the ground view stays within 400 tiles", at_pilot > 40 and at_pilot <= 400, str(at_pilot))
		var high: int = view.update_for(Vector3(0.0, 4000.0, 0.0))
		check("tiles coarsen with altitude", high < at_pilot, "%d at 4 km, %d at the pilot" % [high, at_pilot])
	var mesh: ArrayMesh = TerrainView.build_tile_mesh()
	var vertex_count: int = (mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	check("the tile mesh is 65 x 65 vertices plus four skirts", vertex_count == 65 * 65 + 4 * 65, str(vertex_count))

	# The first tree record's instance sits on its baked ground height.
	var data := FileAccess.get_file_as_bytes(ROOT + "vegetation/trees.bin.gz").decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	var first_east := data.decode_u16(0) * 0.2
	var first_north := data.decode_u16(2) * 0.2
	var first_ground := 600.0 + data.decode_u16(4) / 32.0
	var instances := 0
	for chunk: Node in field.get_node("Trees").get_children():
		instances += (chunk as MultiMeshInstance3D).multimesh.instance_count
	check("tree chunks hold every record once", instances == int(trees_header.count), str(instances))
	var detail: Dictionary = preload("res://render/scene_detail.gd").profile()
	var chunk0: GeometryInstance3D = field.get_node("Trees").get_child(0)
	check("Scene detail sets the tree draw range", chunk0.visibility_range_end == float(detail.landscape_tree_range_m),
		str(chunk0.visibility_range_end))
	check("baked ground under trees matches the core within 0.5 m",
		absf(first_ground - core.height_at(first_east, first_north)) < 0.5)

	field.queue_free()
	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
