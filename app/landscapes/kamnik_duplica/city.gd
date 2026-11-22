extends RefCounted
## Option 7b: Ljubljana's skyline for the Kamnik landscape (research/kamnik/KM-03/bake_city.py, `openrc-city-blocks
## v1`). The city lies 12-20 km from the pilot, beyond the surveyed core, so it is drawn as blocks: one 12.5 m box
## per mostly-roofed cell, from its ground to the 90th percentile of its roofs, coloured by its roofs. One MultiMesh
## per 1 km sheet keeps the draw calls few and lets each sheet be culled. Visual only: the blocks are not solid.

const SHADER = preload("res://landscapes/kamnik_duplica/city.gdshader")
const FORMAT := "openrc-city-blocks v1"
const RECORD_BYTES := 12
const CELLS_PER_CHUNK := 80
## Blocks reach this far below their ground so the coarser ring terrain never shows a gap under them.
const SINK_M := 4.0


## {node, materials, count, error}. `origin_abs` is the D96/TM position of render (0, 0) and `ground_ref_m` the height
## at render y = 0.
static func build(json_path: String, origin_abs: Vector2, ground_ref_m: float) -> Dictionary:
	var root := Node3D.new()
	root.name = "City"
	var header: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path)) if FileAccess.file_exists(json_path) else null
	if not (header is Dictionary) or str(header.get("format", "")) != FORMAT:
		return {node = root, materials = [], count = 0, error = "city: missing or unreadable %s" % json_path}
	var packed := FileAccess.get_file_as_bytes(json_path.get_base_dir().path_join(str(header.data)))
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(packed)
	if packed.is_empty() or hashing.finish().hex_encode() != str(header.data_sha256):
		return {node = root, materials = [], count = 0, error = "city: checksum mismatch for %s" % json_path}
	var data := packed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if data.size() != int(header.count) * RECORD_BYTES:
		return {node = root, materials = [], count = 0, error = "city: %s holds %d bytes for %d blocks" % [json_path, data.size(), int(header.count)]}
	var cell := float(header.cell_m)
	var origin := Vector2(float(header.origin_east_m), float(header.origin_north_m)) - origin_abs
	var material := ShaderMaterial.new()
	material.shader = SHADER
	var mesh := box_mesh()
	# Group the records by chunk. Arrays, not PackedInt32Arrays: a packed array read from a Dictionary is a copy.
	var chunks: Dictionary = {}
	var count := int(header.count)
	for index in count:
		var at := index * RECORD_BYTES
		var key := Vector2i(data.decode_u16(at) / CELLS_PER_CHUNK, data.decode_u16(at + 2) / CELLS_PER_CHUNK)
		if not chunks.has(key):
			chunks[key] = []
		(chunks[key] as Array).append(at)
	var keys: Array = chunks.keys()
	keys.sort()
	for key: Vector2i in keys:
		var offsets: Array = chunks[key]
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.use_colors = true
		multi.mesh = mesh
		multi.instance_count = offsets.size()
		# One flat buffer per sheet, as the trees do (trees.gd): per block a row-major 3 x 4 transform, then the colour.
		var flat := PackedFloat32Array()
		flat.resize(offsets.size() * 16)
		var low := Vector3(INF, INF, INF)
		var high := -low
		for i in offsets.size():
			var at: int = offsets[i]
			var east := origin.x + (data.decode_u16(at) + 0.5) * cell
			var north := origin.y + (data.decode_u16(at + 2) + 0.5) * cell
			var ground := data.decode_u16(at + 4) / 10.0 - ground_ref_m
			var height := data.decode_u16(at + 6) / 10.0
			var o := i * 16
			flat[o] = cell
			flat[o + 3] = east
			flat[o + 5] = height + SINK_M
			flat[o + 7] = ground - SINK_M
			flat[o + 10] = cell
			flat[o + 11] = -north
			flat[o + 12] = data[at + 8] / 255.0
			flat[o + 13] = data[at + 9] / 255.0
			flat[o + 14] = data[at + 10] / 255.0
			flat[o + 15] = 1.0
			low = low.min(Vector3(east - cell * 0.5, ground - SINK_M, -north - cell * 0.5))
			high = high.max(Vector3(east + cell * 0.5, ground + height, -north + cell * 0.5))
		multi.buffer = flat
		var instance := MultiMeshInstance3D.new()
		instance.name = "Sheet%d_%d" % [key.x, key.y]
		instance.multimesh = multi
		# The MultiMesh's own AABB is not known until the renderer syncs it, so culling would drop the whole sheet.
		instance.custom_aabb = AABB(low, high - low)
		instance.material_override = material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(instance)
	return {node = root, materials = [material], count = count, error = ""}


## A unit block: x and z from -0.5 to 0.5, y from 0 to 1, without a floor.
static func box_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c := [Vector3(-0.5, 0, -0.5), Vector3(0.5, 0, -0.5), Vector3(0.5, 0, 0.5), Vector3(-0.5, 0, 0.5)]
	var t := [Vector3(-0.5, 1, -0.5), Vector3(0.5, 1, -0.5), Vector3(0.5, 1, 0.5), Vector3(-0.5, 1, 0.5)]
	_quad(st, t[0], t[1], t[2], t[3], Vector3.UP)
	for side in 4:
		var a: Vector3 = c[side]
		var b: Vector3 = c[(side + 1) % 4]
		var normal := Vector3((a.x + b.x), 0, (a.z + b.z)).normalized()
		_quad(st, t[side], a, b, t[(side + 1) % 4], normal)
	return st.commit()


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3) -> void:
	for v: Vector3 in [a, b, c, a, c, d]:
		st.set_normal(normal)
		st.add_vertex(v)
