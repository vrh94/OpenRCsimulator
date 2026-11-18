extends RefCounted
## Step 21 (TG-03): the Planica and Tamar valleys in Triglav National Park from the national LiDAR and orthophoto
## (docs/plans/triglav-planica-tamar.md, research/triglav/README.md). The render origin is the pilot spot on the
## Tamar meadow; render x is grid east, render z grid south (D96/TM grid north is 0.94 degrees east of true north here).

const Atmosphere = preload("res://render/atmosphere.gd")
const Heightfield = preload("res://landscapes/triglav_tamar/heightfield.gd")
const TerrainView = preload("res://landscapes/triglav_tamar/terrain_view.gd")
const Trees = preload("res://landscapes/triglav_tamar/trees.gd")
const Buildings = preload("res://landscapes/triglav_tamar/buildings.gd")
const TERRAIN_SHADER = preload("res://landscapes/triglav_tamar/terrain.gdshader")

const ID: String = "triglav_tamar"
const DISPLAY_NAME: String = "Triglav: Planica and Tamar"
const FIELD_PATH: String = "res://landscapes/triglav_tamar/field.json"
const ROOT := "res://landscapes/triglav_tamar/"
## The pilot spot in the core frame (metres east and north of D96/TM E 399000, N 144000): the middle of the Tamar
## meadow, 140 m north of Dom v Tamarju (D96/TM E 401136, N 146098), where GKOT shows no tree or roof within 30 m
## and the ground slopes less than 4 degrees.
const PILOT_CORE := Vector2(2136.0, 2098.0)
const PHOTO_PATH := ROOT + "photo/ortho.jpg"
const COVERAGE_PATH := ROOT + "photo/coverage.png"
## CC0 (assets/landscape/mountains/LICENSES.md): brightness detail on the near ground.
const NEAR_DETAIL_PATH := "res://assets/landscape/mountains/aerial_grass_rock_diff_1k.jpg"


static func build(_field: Dictionary, lighting: Dictionary = {}) -> Node3D:
	var result := Node3D.new()
	result.name = "Field"
	var core: RefCounted = Heightfield.load_grid(ROOT + "terrain/core.json")
	var ring: RefCounted = Heightfield.load_grid(ROOT + "terrain/ring.json")
	if not core.ok() or not ring.ok():
		push_error("triglav_tamar: %s %s" % [core.error, ring.error])
		result.set_meta("lighting_materials", [] as Array[ShaderMaterial])
		result.set_meta("lighting_snapshot", lighting.duplicate(true))
		return result
	var ground_ref: float = core.height_at(PILOT_CORE.x, PILOT_CORE.y)
	var material := terrain_material(core, ring, ground_ref)
	Atmosphere.update_ground_material(material, lighting)
	var view: Node3D = TerrainView.new()
	view.name = "Terrain"
	result.add_child(view)
	view.setup(core, ring, material, PILOT_CORE, ground_ref)
	var materials: Array[ShaderMaterial] = [material]
	var photo: Texture2D = material.get_shader_parameter("photo") as Texture2D
	for part: Dictionary in [
		Trees.build(ROOT + "vegetation/trees.bin.gz", photo, PILOT_CORE, ground_ref),
		Buildings.build(ROOT + "buildings/buildings.bin.gz", photo, PILOT_CORE, ground_ref),
	]:
		if not str(part.error).is_empty():
			push_warning("triglav_tamar: " + str(part.error))
		result.add_child(part.node)
		for part_material: ShaderMaterial in part.materials:
			Atmosphere.update_ground_material(part_material, lighting)
			materials.append(part_material)
		result.set_meta("%s_count" % str(part.node.name).to_lower(), part.count)
	result.set_meta("lighting_materials", materials)
	result.set_meta("lighting_snapshot", lighting.duplicate(true))
	result.set_meta("terrain_ground_ref_m", ground_ref)
	return result


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


static func collision_world(_field: Dictionary) -> Dictionary:
	return {ok = true, world = {}, errors = PackedStringArray()}
