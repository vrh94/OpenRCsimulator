extends RefCounted
## Option 7 (2026-11-22): the Kamnik (Duplica) airstrip in the Ljubljana basin, from the national LiDAR and
## orthophoto, with the Kamnik Alps, Krvavec, Rašica and Šmarna gora around it (research/kamnik/README.md). The
## surveyed core is 8 x 8 km at 2 m; the 48 x 48 km ring (SRTM, coloured by Sentinel-2) carries the distant mountains.
## Ljubljana's skyline (city.gd) stands on the ring's LiDAR ground 12-20 km south-west.
## The render origin is the model flyers' spot at threshold 29; render x is grid east, render z grid south
## (D96/TM grid north is 0.30 degrees west of true north here).
##
## The terrain, trees, buildings and obstacles reuse the Triglav landscape's code (landscapes/triglav_tamar/) with
## this region's grids and photos.

const Atmosphere = preload("res://render/atmosphere.gd")
const Heightfield = preload("res://landscapes/triglav_tamar/heightfield.gd")
const TerrainDem = preload("res://physics/terrain_dem.gd")
const TerrainView = preload("res://landscapes/triglav_tamar/terrain_view.gd")
const Trees = preload("res://landscapes/triglav_tamar/trees.gd")
const Buildings = preload("res://landscapes/triglav_tamar/buildings.gd")
const Obstacles = preload("res://landscapes/triglav_tamar/obstacles.gd")
const TriglavLandscape = preload("res://landscapes/triglav_tamar/landscape.gd")
const SceneDetail = preload("res://render/scene_detail.gd")
const TERRAIN_SHADER = preload("res://landscapes/triglav_tamar/terrain.gdshader")
const City = preload("res://landscapes/kamnik_duplica/city.gd")

const ID: String = "kamnik_duplica"
const DISPLAY_NAME: String = "Kamnik: Duplica airstrip"
const FIELD_PATH: String = "res://landscapes/kamnik_duplica/field.json"
const ROOT := "res://landscapes/kamnik_duplica/"
## The core's south-west corner (D96/TM, metres): E 464 km, N 114 km.
const CORE_ORIGIN := Vector2(464000.0, 114000.0)
## The pilot spot in the core frame (metres east and north of CORE_ORIGIN). Matches field.json terrain.origin_*.
const PILOT_CORE := Vector2(3840.0, 3512.0)
## Trees store their ground height above the core grid's base (research/triglav/region.py core_base_m).
const TREE_GROUND_BASE_M := 250.0
const PHOTO_PATH := ROOT + "photo/ortho.jpg"
const COVERAGE_PATH := ROOT + "photo/coverage.png"
const RING_PHOTO_PATH := ROOT + "photo/ring.jpg"
const RING_PHOTO_HEADER := ROOT + "photo/ring.json"
## The core photo fades into the satellite ring photo over this band inside the core edge.
const CORE_PHOTO_FADE_M := 400.0
const NEAR_DETAIL_PATH := "res://assets/landscape/mountains/aerial_grass_rock_diff_1k.jpg"
## The Kamnik Alps stand 18-25 km north and the ring reaches 34 km at its corners: the default 21 km far plane would
## cut the ridge off. landscapes/catalog.gd hands this to the flight camera.
const CAMERA_FAR_M := 36000.0


static func build(field: Dictionary, lighting: Dictionary = {}) -> Node3D:
	var result := Node3D.new()
	result.name = "Field"
	var core: RefCounted = Heightfield.load_grid(ROOT + "terrain/core.json", CORE_ORIGIN)
	var ring: RefCounted = Heightfield.load_grid(ROOT + "terrain/ring.json", CORE_ORIGIN)
	if not core.ok() or not ring.ok():
		push_error("kamnik_duplica: %s %s" % [core.error, ring.error])
		result.set_meta("lighting_materials", [] as Array[ShaderMaterial])
		result.set_meta("lighting_snapshot", lighting.duplicate(true))
		return result
	# Render height zero is the physics datum (physics/terrain_dem.gd), so drawn and solid ground coincide.
	var dem: RefCounted = _dem()
	var ground_ref: float = dem.ground_ref_m if dem.ok() else core.height_at(PILOT_CORE.x, PILOT_CORE.y)
	var material := terrain_material(core, ring, ground_ref)
	Atmosphere.update_ground_material(material, lighting)
	var view: Node3D = TerrainView.new()
	view.name = "Terrain"
	result.add_child(view)
	view.setup(core, ring, material, PILOT_CORE, ground_ref)
	var materials: Array[ShaderMaterial] = [material]
	var photo: Texture2D = material.get_shader_parameter("photo") as Texture2D
	var detail: Dictionary = SceneDetail.profile()
	var parts: Array[Dictionary] = []
	if FileAccess.file_exists(ROOT + "vegetation/trees.bin.gz"):
		parts.append(Trees.build(ROOT + "vegetation/trees.bin.gz", photo, PILOT_CORE, ground_ref,
			float(detail.landscape_tree_range_m), TREE_GROUND_BASE_M))
	if FileAccess.file_exists(ROOT + "buildings/buildings.bin.gz"):
		parts.append(Buildings.build(ROOT + "buildings/buildings.bin.gz", photo, PILOT_CORE, ground_ref,
			float(detail.landscape_building_range_m)))
	# Option 7b: Ljubljana's skyline, 12-20 km south-west (city.gd).
	if FileAccess.file_exists(ROOT + "city/city.json"):
		parts.append(City.build(ROOT + "city/city.json", CORE_ORIGIN + PILOT_CORE, ground_ref))
	for part: Dictionary in parts:
		if not str(part.error).is_empty():
			push_warning("kamnik_duplica: " + str(part.error))
		result.add_child(part.node)
		for part_material: ShaderMaterial in part.materials:
			Atmosphere.update_ground_material(part_material, lighting)
			materials.append(part_material)
		result.set_meta("%s_count" % str(part.node.name).to_lower(), part.count)
	if dem.ok():
		for surface: Dictionary in field.get("surfaces", []):
			if str(surface.get("type", "")) == "rotorpad":
				result.add_child(TriglavLandscape.pad_platform(surface, dem))
	result.set_meta("lighting_materials", materials)
	result.set_meta("lighting_snapshot", lighting.duplicate(true))
	result.set_meta("terrain_ground_ref_m", ground_ref)
	return result


static func _dem() -> RefCounted:
	return TerrainDem.load_cached(ROOT + "terrain/core.json", ROOT + "terrain/ring.json",
		CORE_ORIGIN.x + PILOT_CORE.x, CORE_ORIGIN.y + PILOT_CORE.y)


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
		material.set_shader_parameter("core_photo_fade_m", CORE_PHOTO_FADE_M)
	var ring_photo := ring_photo_frame()
	material.set_shader_parameter("ring_photo_enabled", not ring_photo.is_empty())
	if not ring_photo.is_empty():
		material.set_shader_parameter("ring_photo", load(RING_PHOTO_PATH))
		material.set_shader_parameter("ring_photo_origin", ring_photo.origin)
		material.set_shader_parameter("ring_photo_size_m", ring_photo.size_m)
	var has_detail := ResourceLoader.exists(NEAR_DETAIL_PATH)
	material.set_shader_parameter("near_detail_enabled", has_detail)
	if has_detail:
		material.set_shader_parameter("near_detail", load(NEAR_DETAIL_PATH))
	return material


## {origin (core frame), size_m} of the satellite ring photo, or {} when it or its header is missing.
static func ring_photo_frame() -> Dictionary:
	if not ResourceLoader.exists(RING_PHOTO_PATH) or not FileAccess.file_exists(RING_PHOTO_HEADER):
		return {}
	var header: Variant = JSON.parse_string(FileAccess.get_file_as_string(RING_PHOTO_HEADER))
	if not (header is Dictionary) or str(header.get("format", "")) != "openrc-ring-photo v1":
		return {}
	return {origin = Vector2(float(header.origin_east_m), float(header.origin_north_m)) - CORE_ORIGIN,
		size_m = float(header.size_m)}


## The surveyed trees and buildings near the pilot as solid obstacles (landscapes/triglav_tamar/obstacles.gd).
## Without the GKOT products the landscape has no solid obstacles yet.
static func collision_world(_field: Dictionary) -> Dictionary:
	var dem: RefCounted = _dem()
	if not dem.ok():
		return {ok = false, world = {}, errors = PackedStringArray(["kamnik_duplica: terrain grids are unreadable"])}
	if not FileAccess.file_exists(ROOT + "vegetation/trees.bin.gz") or not FileAccess.file_exists(ROOT + "buildings/buildings.bin.gz"):
		return {ok = false, world = {}, errors = PackedStringArray(["kamnik_duplica: surveyed obstacles are not baked"])}
	return Obstacles.build(ROOT + "vegetation/trees.bin.gz", ROOT + "buildings/buildings.bin.gz", PILOT_CORE,
		dem.ground_ref_m, TREE_GROUND_BASE_M, "kamnik")
