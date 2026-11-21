extends RefCounted
## Step 21 (TG-03): the Planica and Tamar valleys in Triglav National Park from the national LiDAR and orthophoto
## (docs/plans/triglav-planica-tamar.md, research/triglav/README.md). The render origin is the pilot spot on the
## Rateče plain; render x is grid east, render z grid south (D96/TM grid north is 0.94 degrees east of true north here).

const Atmosphere = preload("res://render/atmosphere.gd")
const Heightfield = preload("res://landscapes/triglav_tamar/heightfield.gd")
const TerrainDem = preload("res://physics/terrain_dem.gd")
const TerrainView = preload("res://landscapes/triglav_tamar/terrain_view.gd")
const Trees = preload("res://landscapes/triglav_tamar/trees.gd")
const Buildings = preload("res://landscapes/triglav_tamar/buildings.gd")
const Obstacles = preload("res://landscapes/triglav_tamar/obstacles.gd")
const SceneDetail = preload("res://render/scene_detail.gd")
const TERRAIN_SHADER = preload("res://landscapes/triglav_tamar/terrain.gdshader")

const ID: String = "triglav_tamar"
const DISPLAY_NAME: String = "Triglav: Planica and Tamar"
const FIELD_PATH: String = "res://landscapes/triglav_tamar/field.json"
const ROOT := "res://landscapes/triglav_tamar/"
## The pilot spot in the core frame (metres east and north of D96/TM E 399000, N 144000): an open hay meadow on the
## Rateče plain at the mouth of the Planica valley (D96/TM E 401524, N 151124), the nearest level, tree-free ground
## to the valleys (the Tamar meadow falls 6-7 %, too steep for parked models at idle). Matches field.json.
const PILOT_CORE := Vector2(2524.0, 7124.0)
const PHOTO_PATH := ROOT + "photo/ortho.jpg"
const COVERAGE_PATH := ROOT + "photo/coverage.png"
## CC0 (assets/landscape/mountains/LICENSES.md): brightness detail on the near ground.
const NEAR_DETAIL_PATH := "res://assets/landscape/mountains/aerial_grass_rock_diff_1k.jpg"


static func build(field: Dictionary, lighting: Dictionary = {}) -> Node3D:
	var result := Node3D.new()
	result.name = "Field"
	var core: RefCounted = Heightfield.load_grid(ROOT + "terrain/core.json")
	var ring: RefCounted = Heightfield.load_grid(ROOT + "terrain/ring.json")
	if not core.ok() or not ring.ok():
		push_error("triglav_tamar: %s %s" % [core.error, ring.error])
		result.set_meta("lighting_materials", [] as Array[ShaderMaterial])
		result.set_meta("lighting_snapshot", lighting.duplicate(true))
		return result
	# Render height zero is the physics datum (physics/terrain_dem.gd), so drawn and solid ground coincide.
	var dem: RefCounted = TerrainDem.load_cached(ROOT + "terrain/core.json", ROOT + "terrain/ring.json",
		Heightfield.CORE_ORIGIN_EAST_M + PILOT_CORE.x, Heightfield.CORE_ORIGIN_NORTH_M + PILOT_CORE.y)
	var ground_ref: float = dem.ground_ref_m if dem.ok() else core.height_at(PILOT_CORE.x, PILOT_CORE.y)
	var material := terrain_material(core, ring, ground_ref)
	Atmosphere.update_ground_material(material, lighting)
	var view: Node3D = TerrainView.new()
	view.name = "Terrain"
	result.add_child(view)
	view.setup(core, ring, material, PILOT_CORE, ground_ref)
	var materials: Array[ShaderMaterial] = [material]
	var photo: Texture2D = material.get_shader_parameter("photo") as Texture2D
	# Settings > Graphics > Scene detail sets how far the surveyed trees and buildings are drawn.
	var detail: Dictionary = SceneDetail.profile()
	for part: Dictionary in [
		Trees.build(ROOT + "vegetation/trees.bin.gz", photo, PILOT_CORE, ground_ref, float(detail.landscape_tree_range_m)),
		Buildings.build(ROOT + "buildings/buildings.bin.gz", photo, PILOT_CORE, ground_ref,
			float(detail.landscape_building_range_m)),
	]:
		if not str(part.error).is_empty():
			push_warning("triglav_tamar: " + str(part.error))
		result.add_child(part.node)
		for part_material: ShaderMaterial in part.materials:
			Atmosphere.update_ground_material(part_material, lighting)
			materials.append(part_material)
		result.set_meta("%s_count" % str(part.node.name).to_lower(), part.count)
	if dem.ok():
		for surface: Dictionary in field.get("surfaces", []):
			if str(surface.get("type", "")) == "rotorpad":
				result.add_child(pad_platform(surface, dem))
	result.set_meta("lighting_materials", materials)
	result.set_meta("lighting_snapshot", lighting.duplicate(true))
	result.set_meta("terrain_ground_ref_m", ground_ref)
	return result


## The helicopter pad as the physics has it (physics/ground_terrain.gd PAD_BLEND_M): a platform levelled to the
## datum, its grass banks running down to the surveyed ground over the blend width.
static func pad_platform(surface: Dictionary, dem: RefCounted) -> MeshInstance3D:
	const BLEND := 2.0
	var north := float(surface.center_north)
	var east := float(surface.center_east)
	var half_n := float(surface.width_north_south) / 2.0
	var half_e := float(surface.length_east_west) / 2.0
	var top: Array[Vector3] = []
	var foot: Array[Vector3] = []
	for corner: Vector2 in [Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1)]:  # NW, NE, SE, SW
		var n := north + corner.x * half_n
		var e := east + corner.y * half_e
		top.append(Vector3(e, 0.0, -n))
		var fn := north + corner.x * (half_n + BLEND)
		var fe := east + corner.y * (half_e + BLEND)
		foot.append(Vector3(fe, float(dem.sample(fn, fe)[0]) - 0.05, -fn))
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_color(Color(0.42, 0.40, 0.36))
	for i: int in [0, 1, 2, 0, 2, 3]:
		tool.add_vertex(top[i])
	tool.set_color(Color(0.22, 0.27, 0.12))
	for side in 4:
		var a := top[side]
		var b := top[(side + 1) % 4]
		var c := foot[(side + 1) % 4]
		var d := foot[side]
		for v: Vector3 in [a, d, b, b, d, c]:
			tool.add_vertex(v)
	tool.generate_normals()
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var node := MeshInstance3D.new()
	node.name = "HelicopterPad"
	node.mesh = tool.commit()
	node.material_override = material
	return node


static func terrain_material(core: RefCounted, ring: RefCounted, ground_ref: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	for prefix: String in ["core", "ring"]:
		var grid: RefCounted = core if prefix == "core" else ring
		material.set_shader_parameter(prefix + "_h", grid.texture())
		material.set_shader_parameter(prefix + "_origin", Vector2(grid.origin_east, grid.origin_north))
		material.set_shader_parameter(prefix + "_spacing", grid.spacing)
		material.set_shader_parameter(prefix + "_size", Vector2i(grid.columns, grid.rows))
		material.set_shader_parameter(prefix + "_base", grid.base_m)
		material.set_shader_parameter(prefix + "_step", grid.step_m)
	material.set_shader_parameter("pilot_core", PILOT_CORE)
	material.set_shader_parameter("ground_ref_m", ground_ref)
	var has_photo := ResourceLoader.exists(PHOTO_PATH) and ResourceLoader.exists(COVERAGE_PATH)
	material.set_shader_parameter("photo_enabled", has_photo)
	if has_photo:
		material.set_shader_parameter("photo", load(PHOTO_PATH))
		material.set_shader_parameter("photo_coverage", load(COVERAGE_PATH))
	var has_detail := ResourceLoader.exists(NEAR_DETAIL_PATH)
	material.set_shader_parameter("near_detail_enabled", has_detail)
	if has_detail:
		material.set_shader_parameter("near_detail", load(NEAR_DETAIL_PATH))
	return material


## TG-07: the surveyed trees and buildings near the pilot as solid obstacles (obstacles.gd).
static func collision_world(_field: Dictionary) -> Dictionary:
	var dem: RefCounted = TerrainDem.load_cached(ROOT + "terrain/core.json", ROOT + "terrain/ring.json",
		Heightfield.CORE_ORIGIN_EAST_M + PILOT_CORE.x, Heightfield.CORE_ORIGIN_NORTH_M + PILOT_CORE.y)
	if not dem.ok():
		return {ok = false, world = {}, errors = PackedStringArray(["triglav_tamar: terrain grids are unreadable"])}
	return Obstacles.build(ROOT + "vegetation/trees.bin.gz", ROOT + "buildings/buildings.bin.gz", PILOT_CORE,
		dem.ground_ref_m)
