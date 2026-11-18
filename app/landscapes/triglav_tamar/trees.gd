extends RefCounted
## Trees of the Triglav landscape from the baked tree tops (research/triglav/TG-02/bake_gkot.py, `openrc-trees v1`):
## one instance per detected crown, low-poly spruce (conifer) or broadleaf meshes, grouped in 250 m chunks whose
## visibility range is the tree draw distance. Instances sit on the baked ground height of their record.

const SHADER = preload("res://landscapes/triglav_tamar/trees.gdshader")
const RECORD_BYTES := 10
const CHUNK_M := 250.0
const CHUNKS_PER_SIDE := 32
const DEFAULT_RANGE_M := 1500.0


## Returns {node, materials, count, error}. `photo` may be null (then the crowns use their base colours).
static func build(bin_path: String, photo: Texture2D, pilot_core: Vector2, ground_ref_m: float,
		range_m: float = DEFAULT_RANGE_M) -> Dictionary:
	var root := Node3D.new()
	root.name = "Trees"
	var packed := FileAccess.get_file_as_bytes(bin_path)
	if packed.is_empty():
		return {node = root, materials = [], count = 0, error = "trees: missing %s" % bin_path}
	var data := packed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if data.size() % RECORD_BYTES != 0:
		return {node = root, materials = [], count = 0, error = "trees: %s is not a whole number of records" % bin_path}
	var materials: Array[ShaderMaterial] = []
	var meshes := [conifer_mesh(), broadleaf_mesh()]
	for kind in 2:
		var material := ShaderMaterial.new()
		material.shader = SHADER
		material.set_shader_parameter("broadleaf", kind == 1)
		material.set_shader_parameter("pilot_core", pilot_core)
		material.set_shader_parameter("photo_enabled", photo != null)
		if photo != null:
			material.set_shader_parameter("photo", photo)
		materials.append(material)
	# Pass 1: count per chunk and kind, so each buffer is allocated once.
	var count := data.size() / RECORD_BYTES
	var chunk_of := PackedInt32Array()
	chunk_of.resize(count)
	var sizes := PackedInt32Array()
	sizes.resize(CHUNKS_PER_SIDE * CHUNKS_PER_SIDE * 2)
	for index in count:
		var at := index * RECORD_BYTES
		var cx := mini(int(data.decode_u16(at) * 0.2 / CHUNK_M), CHUNKS_PER_SIDE - 1)
		var cy := mini(int(data.decode_u16(at + 2) * 0.2 / CHUNK_M), CHUNKS_PER_SIDE - 1)
		var slot := (cy * CHUNKS_PER_SIDE + cx) * 2 + data[at + 8]
		chunk_of[index] = slot
		sizes[slot] += 1
	# Pass 2: one flat buffer ordered by slot; row-major 3 x 4 per instance, as MultiMesh.buffer expects.
	var start := PackedInt32Array()
	start.resize(sizes.size() + 1)
	for slot in sizes.size():
		start[slot + 1] = start[slot] + sizes[slot]
	var fill := start.duplicate()
	var flat := PackedFloat32Array()
	flat.resize(count * 12)
	for index in count:
		var at := index * RECORD_BYTES
		var east := data.decode_u16(at) * 0.2
		var north := data.decode_u16(at + 2) * 0.2
		var ground := 600.0 + data.decode_u16(at + 4) / 32.0
		var height := maxf(data[at + 6] * 0.25, 2.0)
		var radius := maxf(data[at + 7] * 0.1, 0.6)
		var yaw := fposmod(east * 12.9898 + north * 78.233, TAU)
		var c := cos(yaw) * radius
		var s := sin(yaw) * radius
		var slot := chunk_of[index]
		var o := fill[slot] * 12
		fill[slot] += 1
		flat[o] = c
		flat[o + 2] = s
		flat[o + 3] = east - pilot_core.x
		flat[o + 5] = height
		flat[o + 7] = ground - ground_ref_m
		flat[o + 8] = -s
		flat[o + 10] = c
		flat[o + 11] = pilot_core.y - north
	for slot in sizes.size():
		if sizes[slot] == 0:
			continue
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = meshes[slot % 2]
		multimesh.instance_count = sizes[slot]
		multimesh.buffer = flat.slice(start[slot] * 12, start[slot + 1] * 12)
		var chunk := MultiMeshInstance3D.new()
		chunk.name = "Chunk%d_%s" % [slot / 2, "broadleaf" if slot % 2 == 1 else "conifer"]
		chunk.multimesh = multimesh
		chunk.material_override = materials[slot % 2]
		chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		chunk.visibility_range_end = range_m
		chunk.visibility_range_end_margin = 50.0
		root.add_child(chunk)
	return {node = root, materials = materials, count = count, error = ""}


## Unit spruce: three stacked seven-sided cones (crown radius 1 at the widest, height 1); branches reach almost to
## the ground, as at a forest edge.
static func conifer_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_prism(st, 0.07, 0.0, 0.22)
	for tier: Array in [[0.06, 0.56, 1.0], [0.33, 0.81, 0.72], [0.60, 1.0, 0.45]]:
		_cone(st, tier[0], tier[1], tier[2], 7)
	st.generate_normals()
	return st.commit()


## Unit broadleaf tree: a trunk and a flattened low-poly ellipsoid crown (radius 1, height 0.72, centre 0.62).
static func broadleaf_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_prism(st, 0.06, 0.0, 0.45)
	var rings := 4
	var segments := 7
	var centre := 0.62
	var points: Array[PackedVector3Array] = []
	for r in rings + 1:
		var phi := PI * r / rings
		var ring := PackedVector3Array()
		for k in segments:
			var theta := TAU * k / segments + (0.45 if r % 2 == 1 else 0.0)
			ring.append(Vector3(sin(phi) * cos(theta), centre + 0.36 * cos(phi), sin(phi) * sin(theta)))
		points.append(ring)
	st.set_color(Color(0, 0, 0))
	for r in rings:
		for k in segments:
			var a := points[r][k]
			var b := points[r][(k + 1) % segments]
			var c := points[r + 1][k]
			var d := points[r + 1][(k + 1) % segments]
			_tri(st, a, c, b)
			_tri(st, b, c, d)
	st.generate_normals()
	return st.commit()


static func _cone(st: SurfaceTool, base_y: float, top_y: float, radius: float, segments: int) -> void:
	st.set_color(Color(0, 0, 0))
	var apex := Vector3(0.0, top_y, 0.0)
	var centre := Vector3(0.0, base_y, 0.0)
	for k in segments:
		var a := Vector3(cos(TAU * k / segments) * radius, base_y, sin(TAU * k / segments) * radius)
		var b := Vector3(cos(TAU * (k + 1) / segments) * radius, base_y, sin(TAU * (k + 1) / segments) * radius)
		_tri(st, apex, b, a)
		_tri(st, centre, a, b)


static func _prism(st: SurfaceTool, radius: float, y0: float, y1: float) -> void:
	st.set_color(Color(1, 0, 0))
	for k in 4:
		var a := Vector3(cos(TAU * k / 4.0) * radius, 0.0, sin(TAU * k / 4.0) * radius)
		var b := Vector3(cos(TAU * (k + 1) / 4.0) * radius, 0.0, sin(TAU * (k + 1) / 4.0) * radius)
		_tri(st, a + Vector3(0, y1, 0), b + Vector3(0, y0, 0), a + Vector3(0, y0, 0))
		_tri(st, a + Vector3(0, y1, 0), b + Vector3(0, y1, 0), b + Vector3(0, y0, 0))


## Godot's front faces wind clockwise as seen from outside.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
