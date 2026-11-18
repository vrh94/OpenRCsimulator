extends RefCounted
## Buildings of the Triglav landscape from the baked roof grids (research/triglav/TG-02/bake_gkot.py,
## `openrc-buildings v1`): each record is a 1 m grid of roof heights over a base height. The roof surface takes the
## mean height of the roof cells around each grid corner, so pitched roofs come out smooth; walls stand wherever a
## roof cell borders an empty one and reach down to the base. One mesh per 1 km chunk.

const SHADER = preload("res://landscapes/triglav_tamar/buildings.gdshader")
const CHUNK_M := 1000.0
const CHUNKS_PER_SIDE := 8
const DEFAULT_RANGE_M := 4000.0


## Returns {node, materials, count, triangles, error}.
static func build(bin_path: String, photo: Texture2D, pilot_core: Vector2, ground_ref_m: float,
		range_m: float = DEFAULT_RANGE_M) -> Dictionary:
	var root := Node3D.new()
	root.name = "Buildings"
	var packed := FileAccess.get_file_as_bytes(bin_path)
	if packed.is_empty():
		return {node = root, materials = [], count = 0, triangles = 0, error = "buildings: missing %s" % bin_path}
	var data := packed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	var material := ShaderMaterial.new()
	material.shader = SHADER
	material.set_shader_parameter("pilot_core", pilot_core)
	material.set_shader_parameter("photo_enabled", photo != null)
	if photo != null:
		material.set_shader_parameter("photo", photo)
	var chunk_vertices: Array[PackedVector3Array] = []
	var chunk_normals: Array[PackedVector3Array] = []
	chunk_vertices.resize(CHUNKS_PER_SIDE * CHUNKS_PER_SIDE)
	chunk_normals.resize(CHUNKS_PER_SIDE * CHUNKS_PER_SIDE)
	var at := 0
	var count := 0
	while at + 8 <= data.size():
		var east0 := float(data.decode_u16(at))
		var north0 := float(data.decode_u16(at + 2))
		var columns := int(data[at + 4])
		var rows := int(data[at + 5])
		var base := data.decode_u16(at + 6) / 10.0
		var cells := data.slice(at + 8, at + 8 + columns * rows)
		at += 8 + columns * rows
		if cells.size() != columns * rows:
			return {node = root, materials = [], count = count, triangles = 0, error = "buildings: truncated record"}
		var chunk := clampi(int(north0 / CHUNK_M), 0, CHUNKS_PER_SIDE - 1) * CHUNKS_PER_SIDE \
			+ clampi(int(east0 / CHUNK_M), 0, CHUNKS_PER_SIDE - 1)
		var vertices := chunk_vertices[chunk]
		var normals := chunk_normals[chunk]
		# Packed arrays are copy-on-write: release the list's reference so the appends do not copy the chunk.
		chunk_vertices[chunk] = PackedVector3Array()
		chunk_normals[chunk] = PackedVector3Array()
		_append_building(vertices, normals, cells, columns, rows,
			Vector3(east0 - pilot_core.x, base - ground_ref_m, pilot_core.y - north0), base)
		chunk_vertices[chunk] = vertices
		chunk_normals[chunk] = normals
		count += 1
	var triangles := 0
	for chunk in chunk_vertices.size():
		var vertices := chunk_vertices[chunk]
		if vertices.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = chunk_normals[chunk]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var instance := MeshInstance3D.new()
		instance.name = "Chunk%d" % chunk
		instance.mesh = mesh
		instance.material_override = material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.visibility_range_end = range_m
		root.add_child(instance)
		triangles += vertices.size() / 3
	return {node = root, materials = [material], count = count, triangles = triangles, error = ""}


## `origin`: render position of the record's south-west cell corner at the base height. Cells rows run south to
## north; render z = -north.
static func _append_building(vertices: PackedVector3Array, normals: PackedVector3Array, cells: PackedByteArray,
		columns: int, rows: int, origin: Vector3, _base: float) -> void:
	# Corner heights above the base: mean of the roof cells touching each corner.
	var corner := PackedFloat32Array()
	corner.resize((columns + 1) * (rows + 1))
	for j in rows + 1:
		for i in columns + 1:
			var total := 0.0
			var n := 0
			for dj in [-1, 0]:
				for di in [-1, 0]:
					var c: int = i + di
					var r: int = j + dj
					if c >= 0 and r >= 0 and c < columns and r < rows:
						var v := cells[r * columns + c]
						if v > 0:
							total += v * 0.2
							n += 1
			corner[j * (columns + 1) + i] = total / n if n > 0 else 0.0
	for r in rows:
		for c in columns:
			if cells[r * columns + c] == 0:
				continue
			var sw := _corner(origin, corner, columns, c, r)
			var se := _corner(origin, corner, columns, c + 1, r)
			var nw := _corner(origin, corner, columns, c, r + 1)
			var ne := _corner(origin, corner, columns, c + 1, r + 1)
			_quad(vertices, normals, nw, ne, se, sw)
			var low := origin.y
			if r == 0 or cells[(r - 1) * columns + c] == 0:            # south wall
				_quad(vertices, normals, sw, se, Vector3(se.x, low, se.z), Vector3(sw.x, low, sw.z))
			if r == rows - 1 or cells[(r + 1) * columns + c] == 0:     # north wall
				_quad(vertices, normals, ne, nw, Vector3(nw.x, low, nw.z), Vector3(ne.x, low, ne.z))
			if c == columns - 1 or cells[r * columns + c + 1] == 0:    # east wall
				_quad(vertices, normals, se, ne, Vector3(ne.x, low, ne.z), Vector3(se.x, low, se.z))
			if c == 0 or cells[r * columns + c - 1] == 0:              # west wall
				_quad(vertices, normals, nw, sw, Vector3(sw.x, low, sw.z), Vector3(nw.x, low, nw.z))


static func _corner(origin: Vector3, corner: PackedFloat32Array, columns: int, i: int, j: int) -> Vector3:
	return origin + Vector3(i, corner[j * (columns + 1) + i], -j)


## A quad given clockwise from its top-left as seen from the front: two triangles with a flat normal.
static func _quad(vertices: PackedVector3Array, normals: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3,
		d: Vector3) -> void:
	var normal := (c - a).cross(b - a).normalized()
	vertices.append_array([a, b, c, a, c, d])
	normals.append_array([normal, normal, normal, normal, normal, normal])
