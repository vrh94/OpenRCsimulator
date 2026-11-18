extends Node3D
## Quadtree level of detail for the Triglav terrain (terrain.gdshader). Every node is the same 64 x 64 grid tile,
## scaled and placed by its transform; a node splits while the camera is nearer than `split_factor` times its size.
## Leaves are 128 m (2 m spacing) inside the 8 km core and 512 m (8 m spacing; the ring data is 16 m) outside.
## Coordinates: the core frame (metres east and north of D96/TM E 399000, N 144000); render x = east,
## render z = -north, render y = height - ground_ref_m, with the render origin at `pilot_core`.

const TILE_QUADS := 64
const ROOT_SIZE_M := 65536.0
const CORE_LEAF_M := 128.0
const RING_LEAF_M := 512.0
const CORE_SIZE_M := 8000.0
const UPDATE_MOVE_M := 4.0

var core: RefCounted
var ring: RefCounted
var material: ShaderMaterial
var pilot_core := Vector2.ZERO
var ground_ref_m := 0.0
## Larger is finer (more nodes); quality presets scale it.
var split_factor := 1.6
## Tests and captures pin the camera; otherwise the viewport's active camera is followed.
var camera_override: Camera3D = null
var node_count := 0

var _mesh: ArrayMesh
var _pool: Array[MeshInstance3D] = []
var _last_camera := Vector3(INF, INF, INF)
var _root_origin := Vector2.ZERO


func setup(core_grid: RefCounted, ring_grid: RefCounted, terrain_material: ShaderMaterial, pilot: Vector2,
		ground_ref: float) -> void:
	core = core_grid
	ring = ring_grid
	material = terrain_material
	pilot_core = pilot
	ground_ref_m = ground_ref
	_root_origin = Vector2(CORE_SIZE_M / 2.0 - ROOT_SIZE_M / 2.0, CORE_SIZE_M / 2.0 - ROOT_SIZE_M / 2.0)
	_mesh = build_tile_mesh()
	update_for(Vector3(0.0, 2.0, 0.0))


func _process(_delta: float) -> void:
	var camera: Camera3D = camera_override if camera_override != null else get_viewport().get_camera_3d()
	if camera == null:
		return
	var position_now := camera.global_position
	if position_now.distance_to(_last_camera) >= UPDATE_MOVE_M:
		update_for(position_now)


## Selects the nodes for a render-space camera position and places the tiles; returns the node count.
func update_for(camera_render: Vector3) -> int:
	_last_camera = camera_render
	var camera_core := Vector2(pilot_core.x + camera_render.x, pilot_core.y - camera_render.z)
	var camera_height := ground_ref_m + camera_render.y
	var nodes: Array[Vector3] = []
	_select(_root_origin, ROOT_SIZE_M, camera_core, camera_height, nodes)
	while _pool.size() < nodes.size():
		var tile := MeshInstance3D.new()
		tile.mesh = _mesh
		tile.material_override = material
		tile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		tile.name = "Tile%d" % _pool.size()
		add_child(tile)
		_pool.append(tile)
	for index in _pool.size():
		var tile: MeshInstance3D = _pool[index]
		if index >= nodes.size():
			tile.visible = false
			continue
		var node: Vector3 = nodes[index]   # x, y: south-west corner (core frame); z: size
		var size := node.z
		tile.transform = Transform3D(Basis.from_scale(Vector3(size, 1.0, size)),
			Vector3(node.x - pilot_core.x, 0.0, pilot_core.y - node.y - size))
		tile.visible = true
	node_count = nodes.size()
	return node_count


func _select(origin: Vector2, size: float, camera_core: Vector2, camera_height: float, out: Array[Vector3]) -> void:
	var leaf := CORE_LEAF_M if _touches_core(origin, size) else RING_LEAF_M
	if size > leaf and _distance(origin, size, camera_core, camera_height) < split_factor * size:
		var half := size / 2.0
		for offset: Vector2 in [Vector2(0, 0), Vector2(half, 0), Vector2(0, half), Vector2(half, half)]:
			_select(origin + offset, half, camera_core, camera_height, out)
		return
	out.append(Vector3(origin.x, origin.y, size))


func _touches_core(origin: Vector2, size: float) -> bool:
	return origin.x < CORE_SIZE_M and origin.y < CORE_SIZE_M and origin.x + size > 0.0 and origin.y + size > 0.0


func _distance(origin: Vector2, size: float, camera_core: Vector2, camera_height: float) -> float:
	var nearest := Vector2(clampf(camera_core.x, origin.x, origin.x + size), clampf(camera_core.y, origin.y, origin.y + size))
	var ground: float = ring.height_at(nearest.x, nearest.y)
	return Vector3(nearest.x - camera_core.x, ground - camera_height, nearest.y - camera_core.y).length()


## A unit tile in x and z (0..1) with TILE_QUADS quads a side; y = 1 marks the skirt vertices below each edge.
## Skirts carry both windings so no camera angle shows a hole.
static func build_tile_mesh() -> ArrayMesh:
	var n := TILE_QUADS
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for j in n + 1:
		for i in n + 1:
			vertices.append(Vector3(float(i) / n, 0.0, float(j) / n))
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			var b := a + 1
			var c := a + n + 1
			var d := c + 1
			indices.append_array([a, b, c, b, d, c])
	var edge_lists := [
		range(n + 1).map(func(k: int) -> int: return k),                       # j = 0
		range(n + 1).map(func(k: int) -> int: return n * (n + 1) + k),         # j = n
		range(n + 1).map(func(k: int) -> int: return k * (n + 1)),             # i = 0
		range(n + 1).map(func(k: int) -> int: return k * (n + 1) + n),         # i = n
	]
	for edge: Array in edge_lists:
		var first_skirt := vertices.size()
		for top: int in edge:
			var v := vertices[top]
			vertices.append(Vector3(v.x, 1.0, v.z))
		for k in edge.size() - 1:
			var t0: int = edge[k]
			var t1: int = edge[k + 1]
			var s0 := first_skirt + k
			var s1 := s0 + 1
			indices.append_array([t0, t1, s0, t1, s1, s0, t0, s0, t1, t1, s0, s1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# The shader moves vertices to the terrain height: cover every height the region can have (relative metres).
	mesh.custom_aabb = AABB(Vector3(0.0, -3000.0, 0.0), Vector3(1.0, 6000.0, 1.0))
	return mesh
