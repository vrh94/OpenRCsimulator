extends RefCounted
## TG-07: the surveyed trees and buildings of the Triglav landscape as solid obstacles (scenery/collision_world.gd),
## shaped like the meshes the landscape draws (trees.gd, buildings.gd). Only those within RADIUS_M of the pilot are
## solid: a flight log carries the whole obstacle inventory in its header, and the full core's 715,290 trees would
## make that inventory about a hundred times the club field's. Farther scenery is drawn but not solid.

const CollisionWorld = preload("res://scenery/collision_world.gd")

const RADIUS_M := 600.0
const TREE_RECORD_BYTES := 10
## Estimated gameplay envelopes from the drawn meshes (trees.gd): a spruce's stem is stiff through the lower half of
## its height although the drawn trunk ends at 0.22; a broadleaf's drawn trunk ends at 0.45. Crowns span the drawn
## cones or ellipsoid: spruce 0.06 to 1.0 of the height, broadleaf 0.26 to 0.98, both out to the record's radius.
const TRUNK_TOP_FRACTIONS := [0.5, 0.45]
const CROWN_FRACTIONS := [[0.06, 1.0], [0.26, 0.98]]
const MIN_TRUNK_RADIUS_M := 0.12
## Roof grids are merged into blocks of this many 1 m cells a side, each as tall as its highest cell.
const BUILDING_BLOCK_CELLS := 4

static var _cache_key := ""
static var _cache := {}


## {ok, world, errors}. `pilot_core` is the field origin in the core frame and `ground_ref_m` its absolute height.
## `tree_ground_base_m` is the trees' uint16 ground base (trees.gd); `id_prefix` names the landscape in proxy ids.
static func build(trees_path: String, buildings_path: String, pilot_core: Vector2, ground_ref_m: float,
		tree_ground_base_m: float = 600.0, id_prefix: String = "triglav") -> Dictionary:
	var key := "%s|%s|%s|%s|%s|%s" % [trees_path, buildings_path, pilot_core, ground_ref_m, tree_ground_base_m, id_prefix]
	if key == _cache_key:
		return _cache.duplicate(true)
	var proxies: Array[Dictionary] = []
	var errors := PackedStringArray()
	var trees := _decompress(trees_path)
	if trees.is_empty() or trees.size() % TREE_RECORD_BYTES != 0:
		errors.append("triglav obstacles: unreadable %s" % trees_path)
	else:
		_add_trees(proxies, trees, pilot_core, ground_ref_m, tree_ground_base_m, id_prefix)
	var buildings := _decompress(buildings_path)
	if buildings.is_empty():
		errors.append("triglav obstacles: unreadable %s" % buildings_path)
	elif not _add_buildings(proxies, buildings, pilot_core, ground_ref_m, id_prefix):
		errors.append("triglav obstacles: truncated building record")
	if not errors.is_empty():
		return {ok = false, world = {}, errors = errors}
	var result: Dictionary = CollisionWorld.from_proxies(proxies)
	if bool(result.get("ok", false)):
		_cache_key = key
		_cache = result.duplicate(true)
	return result


static func _decompress(path: String) -> PackedByteArray:
	var packed := FileAccess.get_file_as_bytes(path)
	return PackedByteArray() if packed.is_empty() else packed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)


static func _add_trees(proxies: Array[Dictionary], data: PackedByteArray, pilot_core: Vector2, ground_ref_m: float,
		ground_base_m: float, id_prefix: String) -> void:
	for index in data.size() / TREE_RECORD_BYTES:
		var at := index * TREE_RECORD_BYTES
		var north := data.decode_u16(at + 2) * 0.2 - pilot_core.y
		var east := data.decode_u16(at) * 0.2 - pilot_core.x
		if north * north + east * east > RADIUS_M * RADIUS_M:
			continue
		# The same decoding as trees.gd, so the solid tree stands where the drawn one does.
		var base_down := -(ground_base_m + data.decode_u16(at + 4) / 32.0 - ground_ref_m)
		var height := maxf(data[at + 6] * 0.25, 2.0)
		var radius := maxf(data[at + 7] * 0.1, 0.6)
		var kind := clampi(data[at + 8], 0, 1)
		var trunk_radius := maxf(0.07 * radius, MIN_TRUNK_RADIUS_M)
		var trunk_top: float = height * TRUNK_TOP_FRACTIONS[kind]
		var id := "tree:%s:%06d" % [id_prefix, index]
		CollisionWorld.capsule_proxy(proxies, id + ":trunk", "tree_trunk", "trunk", "hard_terminal",
			north, east, base_down - trunk_top * 0.5, trunk_radius, maxf(trunk_top * 0.5 - trunk_radius, 0.0))
		var crown: Array = CROWN_FRACTIONS[kind]
		var crown_height: float = height * (float(crown[1]) - float(crown[0]))
		CollisionWorld.box_proxy(proxies, id + ":crown", "tree_foliage", "crown", "soft_foliage_impulse",
			north, east, base_down - height * float(crown[0]) - crown_height * 0.5,
			radius * 2.0, crown_height, radius * 2.0, 0.0)


static func _add_buildings(proxies: Array[Dictionary], data: PackedByteArray, pilot_core: Vector2,
		ground_ref_m: float, id_prefix: String) -> bool:
	var at := 0
	var record := 0
	while at + 8 <= data.size():
		var east0 := float(data.decode_u16(at)) - pilot_core.x
		var north0 := float(data.decode_u16(at + 2)) - pilot_core.y
		var columns := int(data[at + 4])
		var rows := int(data[at + 5])
		var base := data.decode_u16(at + 6) / 10.0
		var cells := data.slice(at + 8, at + 8 + columns * rows)
		at += 8 + columns * rows
		record += 1
		if cells.size() != columns * rows:
			return false
		var centre_n := north0 + rows * 0.5
		var centre_e := east0 + columns * 0.5
		var reach := RADIUS_M + 0.5 * sqrt(float(columns * columns + rows * rows))
		if centre_n * centre_n + centre_e * centre_e > reach * reach:
			continue
		var base_down := -(base - ground_ref_m)
		# Cells run east along a row and rows run north from the record's south-west corner (buildings.gd).
		for r0 in range(0, rows, BUILDING_BLOCK_CELLS):
			for c0 in range(0, columns, BUILDING_BLOCK_CELLS):
				var top := 0
				var c_lo := columns
				var c_hi := -1
				var r_lo := rows
				var r_hi := -1
				for r in range(r0, mini(r0 + BUILDING_BLOCK_CELLS, rows)):
					for c in range(c0, mini(c0 + BUILDING_BLOCK_CELLS, columns)):
						var v: int = cells[r * columns + c]
						if v == 0:
							continue
						top = maxi(top, v)
						c_lo = mini(c_lo, c)
						c_hi = maxi(c_hi, c)
						r_lo = mini(r_lo, r)
						r_hi = maxi(r_hi, r)
				if top == 0:
					continue
				var tall := top * 0.2
				CollisionWorld.box_proxy(proxies, "building:%s:%04d:%d:%d" % [id_prefix, record, r0, c0], "building",
					"surveyed_building", "hard_terminal",
					north0 + (r_lo + r_hi + 1) * 0.5, east0 + (c_lo + c_hi + 1) * 0.5, base_down - tall * 0.5,
					float(c_hi - c_lo + 1), tall, float(r_hi - r_lo + 1), 0.0)
	return true
