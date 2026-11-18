extends RefCounted
## TG-05: solid real terrain from baked `openrc-heightfield v1` grids (research/triglav/TG-02/bake_terrain.py), named
## by a field's `terrain` block (data/field_loader.gd). A fine core grid (2 m) inside a coarse ring grid (16 m);
## heights are uint16 with height_m = base + value * step, rows south to north, columns west to east.
##
## The field's NED origin sits at the absolute grid point `origin` (D96/TM east, north); field north is grid north.
## Heights are returned positive up relative to `ground_ref_m`, the terrain under the field origin.
##
## Inside the core the height is a Catmull-Rom bicubic patch with analytic derivatives, so the slope is continuous
## for wheels and skids. Within BLEND_M of the core edge it blends into the ring's bilinear surface (the same band
## as landscapes/triglav_tamar/terrain.gdshader). Beyond the ring the edge heights extend flat.
## The grids are immutable after loading, so concurrent sampling is safe.

const FORMAT := "openrc-heightfield v1"
const BLEND_M := 96.0

var identity: String = ""
var error: String = ""
var ground_ref_m := 0.0
var max_up_m := 0.0      ## highest point of both grids above ground_ref_m
var min_up_m := 0.0

# Core grid, in metres relative to the field origin (east = x, north = y).
var _c_data := PackedByteArray()
var _c_cols := 0
var _c_rows := 0
var _c_x0 := 0.0
var _c_y0 := 0.0
var _c_x1 := 0.0
var _c_y1 := 0.0
var _c_spacing := 1.0
var _c_base := 0.0
var _c_step := 1.0
var _c_ref := 0.0        # ground_ref_m in core units: ground_ref_m = _c_base + _c_ref * _c_step
# Ring grid.
var _r_data := PackedByteArray()
var _r_cols := 0
var _r_rows := 0
var _r_x0 := 0.0
var _r_y0 := 0.0
var _r_spacing := 1.0
var _r_base := 0.0
var _r_step := 1.0
var _r_ref := 0.0        # ground_ref_m in ring units

static var _cache: Dictionary = {}
static var _cache_mutex := Mutex.new()


## Loads (once per process) and verifies both grids. Never null; check ok() and error.
static func load_cached(core_json: String, ring_json: String, origin_east: float, origin_north: float) -> RefCounted:
	var key := "%s|%s|%.3f|%.3f" % [core_json, ring_json, origin_east, origin_north]
	_cache_mutex.lock()
	var cached: RefCounted = _cache.get(key)
	_cache_mutex.unlock()
	if cached != null:
		return cached
	var dem: RefCounted = load_grids(core_json, ring_json, origin_east, origin_north)
	if dem.ok():
		_cache_mutex.lock()
		_cache[key] = dem
		_cache_mutex.unlock()
	return dem


static func load_grids(core_json: String, ring_json: String, origin_east: float, origin_north: float) -> RefCounted:
	var dem: RefCounted = new()
	if not is_finite(origin_east) or not is_finite(origin_north):
		dem.error = "terrain_dem: invalid field origin"
		return dem
	var core := _load_one(core_json, origin_east, origin_north)
	var ring := _load_one(ring_json, origin_east, origin_north) if not core.has("error") else {}
	if core.has("error") or ring.has("error"):
		dem.error = str(core.get("error", ring.get("error", "")))
		return dem
	dem._c_data = core.data
	dem._c_cols = core.columns
	dem._c_rows = core.rows
	dem._c_x0 = core.x0
	dem._c_y0 = core.y0
	dem._c_spacing = core.spacing
	dem._c_x1 = dem._c_x0 + (dem._c_cols - 1) * dem._c_spacing
	dem._c_y1 = dem._c_y0 + (dem._c_rows - 1) * dem._c_spacing
	dem._c_base = core.base_m
	dem._c_step = core.step_m
	dem._r_data = ring.data
	dem._r_cols = ring.columns
	dem._r_rows = ring.rows
	dem._r_x0 = ring.x0
	dem._r_y0 = ring.y0
	dem._r_spacing = ring.spacing
	dem._r_base = ring.base_m
	dem._r_step = ring.step_m
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(("%s|%s|%.3f|%.3f" % [core.sha256, ring.sha256, origin_east, origin_north]).to_utf8_buffer())
	dem.identity = "dem-" + digest.finish().hex_encode().substr(0, 24)
	# Heights are interpolated as integer offsets from a nearby node and returned relative to the datum, so the
	# result carries no rounding from the ~1000 m absolute height (contact solvers resolve 1e-11 accelerations).
	var absolute: float = dem._grid_value(0.0, 0.0)[0] # above the base while the references are zero
	dem._c_ref = absolute / dem._c_step
	dem.ground_ref_m = dem._c_base + dem._c_ref * dem._c_step
	dem._r_ref = (dem.ground_ref_m - dem._r_base) / dem._r_step
	dem.max_up_m = maxf(float(core.max_m), float(ring.max_m)) - dem.ground_ref_m
	dem.min_up_m = minf(float(core.min_m), float(ring.min_m)) - dem.ground_ref_m
	return dem


func ok() -> bool:
	return error.is_empty() and not _c_data.is_empty() and not _r_data.is_empty()


## [height_up_m, dh/dnorth, dh/deast] relative to ground_ref_m at a field NED point.
func sample(north: float, east: float) -> PackedFloat64Array:
	var value := _grid_value(east, north)
	return PackedFloat64Array([value[0], value[2], value[1]])


## Absolute height (m) under a field NED point.
func height_m(north: float, east: float) -> float:
	return ground_ref_m + _grid_value(east, north)[0]


## [height above the datum (m), dh/dx, dh/dy] at field-relative east x, north y. Before load_grids sets the
## references (_c_ref = _r_ref = 0) the height is measured from the grids' base instead.
func _grid_value(x: float, y: float) -> PackedFloat64Array:
	var inset := minf(minf(x - _c_x0, _c_x1 - x), minf(y - _c_y0, _c_y1 - y))
	if inset >= BLEND_M:
		return _bicubic(x, y)
	var ring := _bilinear(x, y)
	if inset <= 0.0:
		return ring
	var fine := _bicubic(x, y)
	# Smoothstep blend; its gradient points inward from the nearest core edge, so the slope stays continuous.
	var gx := 0.0
	var gy := 0.0
	if inset == x - _c_x0: gx = 1.0
	elif inset == _c_x1 - x: gx = -1.0
	elif inset == y - _c_y0: gy = 1.0
	else: gy = -1.0
	var t := inset / BLEND_M
	var w := t * t * (3.0 - 2.0 * t)
	var dw := 6.0 * t * (1.0 - t) / BLEND_M
	var diff: float = fine[0] - ring[0]
	return PackedFloat64Array([
		ring[0] + w * diff,
		ring[1] + w * (fine[1] - ring[1]) + dw * gx * diff,
		ring[2] + w * (fine[2] - ring[2]) + dw * gy * diff,
	])


func _ring_node(column: int, row: int) -> int:
	column = clampi(column, 0, _r_cols - 1)
	row = clampi(row, 0, _r_rows - 1)
	return _r_data.decode_u16((row * _r_cols + column) * 2)


func _bilinear(x: float, y: float) -> PackedFloat64Array:
	var u := (x - _r_x0) / _r_spacing
	var v := (y - _r_y0) / _r_spacing
	var c := floori(u)
	var r := floori(v)
	var fx := clampf(u - c, 0.0, 1.0)
	var fy := clampf(v - r, 0.0, 1.0)
	var n00 := _ring_node(c, r)
	var h10 := float(_ring_node(c + 1, r) - n00)
	var h01 := float(_ring_node(c, r + 1) - n00)
	var h11 := float(_ring_node(c + 1, r + 1) - n00)
	var inside_x := u > 0.0 and u < _r_cols - 1
	var inside_y := v > 0.0 and v < _r_rows - 1
	var offset: float = float(n00) - _r_ref
	return PackedFloat64Array([
		(offset + lerpf(lerpf(0.0, h10, fx), lerpf(h01, h11, fx), fy)) * _r_step,
		(lerpf(h10, h11, fy) - lerpf(0.0, h01, fy)) * _r_step / _r_spacing if inside_x else 0.0,
		(lerpf(h01, h11, fx) - lerpf(0.0, h10, fx)) * _r_step / _r_spacing if inside_y else 0.0,
	])


## Catmull-Rom bicubic over the 4 x 4 neighbourhood of the core: [height, d/dx, d/dy].
func _bicubic(x: float, y: float) -> PackedFloat64Array:
	var u := (x - _c_x0) / _c_spacing
	var v := (y - _c_y0) / _c_spacing
	var c := floori(u)
	var r := floori(v)
	var tx := u - c
	var ty := v - r
	var tx2 := tx * tx
	var ty2 := ty * ty
	var wx0 := 0.5 * (-tx2 * tx + 2.0 * tx2 - tx)
	var wx1 := 0.5 * (3.0 * tx2 * tx - 5.0 * tx2 + 2.0)
	var wx2 := 0.5 * (-3.0 * tx2 * tx + 4.0 * tx2 + tx)
	var wx3 := 0.5 * (tx2 * tx - tx2)
	var dx0 := 0.5 * (-3.0 * tx2 + 4.0 * tx - 1.0)
	var dx1 := 0.5 * (9.0 * tx2 - 10.0 * tx)
	var dx2 := 0.5 * (-9.0 * tx2 + 8.0 * tx + 1.0)
	var dx3 := 0.5 * (3.0 * tx2 - 2.0 * tx)
	var wy := PackedFloat64Array([0.5 * (-ty2 * ty + 2.0 * ty2 - ty), 0.5 * (3.0 * ty2 * ty - 5.0 * ty2 + 2.0),
		0.5 * (-3.0 * ty2 * ty + 4.0 * ty2 + ty), 0.5 * (ty2 * ty - ty2)])
	var dy := PackedFloat64Array([0.5 * (-3.0 * ty2 + 4.0 * ty - 1.0), 0.5 * (9.0 * ty2 - 10.0 * ty),
		0.5 * (-9.0 * ty2 + 8.0 * ty + 1.0), 0.5 * (3.0 * ty2 - 2.0 * ty)])
	var interior := c >= 1 and r >= 1 and c + 2 < _c_cols and r + 2 < _c_rows
	var ref: int = _c_data.decode_u16((clampi(r, 0, _c_rows - 1) * _c_cols + clampi(c, 0, _c_cols - 1)) * 2)
	var h := 0.0
	var hx := 0.0
	var hy := 0.0
	for j in 4:
		var n0: float
		var n1: float
		var n2: float
		var n3: float
		if interior:
			var i := ((r - 1 + j) * _c_cols + c - 1) * 2
			n0 = _c_data.decode_u16(i) - ref
			n1 = _c_data.decode_u16(i + 2) - ref
			n2 = _c_data.decode_u16(i + 4) - ref
			n3 = _c_data.decode_u16(i + 6) - ref
		else:
			var row := clampi(r - 1 + j, 0, _c_rows - 1) * _c_cols
			n0 = _c_data.decode_u16((row + clampi(c - 1, 0, _c_cols - 1)) * 2) - ref
			n1 = _c_data.decode_u16((row + clampi(c, 0, _c_cols - 1)) * 2) - ref
			n2 = _c_data.decode_u16((row + clampi(c + 1, 0, _c_cols - 1)) * 2) - ref
			n3 = _c_data.decode_u16((row + clampi(c + 2, 0, _c_cols - 1)) * 2) - ref
		var row_value := wx0 * n0 + wx1 * n1 + wx2 * n2 + wx3 * n3
		var row_slope := dx0 * n0 + dx1 * n1 + dx2 * n2 + dx3 * n3
		h += wy[j] * row_value
		hx += wy[j] * row_slope
		hy += dy[j] * row_value
	# The weights sum to one (their slopes to zero), so the reference node's offset passes through unchanged.
	return PackedFloat64Array([((float(ref) - _c_ref) + h) * _c_step, hx * _c_step / _c_spacing, hy * _c_step / _c_spacing])


static func _load_one(path: String, origin_east: float, origin_north: float) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {error = "terrain_dem: missing %s" % path}
	var header: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (header is Dictionary) or str(header.get("format", "")) != FORMAT:
		return {error = "terrain_dem: %s is not an %s header" % [path, FORMAT]}
	for key: String in ["data", "data_sha256", "columns", "rows", "origin_east_m", "origin_north_m", "spacing_m",
			"base_m", "step_m", "min_m", "max_m"]:
		if not header.has(key):
			return {error = "terrain_dem: %s lacks %s" % [path, key]}
	var packed := FileAccess.get_file_as_bytes(path.get_base_dir().path_join(str(header.data)))
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(packed)
	var sha := hashing.finish().hex_encode()
	if packed.is_empty() or sha != str(header.data_sha256):
		return {error = "terrain_dem: missing or corrupt data for %s" % path}
	var data := packed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	var columns := int(header.columns)
	var rows := int(header.rows)
	var spacing := float(header.spacing_m)
	var step := float(header.step_m)
	if columns < 4 or rows < 4 or data.size() != columns * rows * 2 or not (spacing > 0.0) or not (step > 0.0):
		return {error = "terrain_dem: %s has the wrong size" % path}
	return {
		columns = columns, rows = rows, data = data, sha256 = sha, spacing = spacing, step_m = step,
		x0 = float(header.origin_east_m) - origin_east, y0 = float(header.origin_north_m) - origin_north,
		base_m = float(header.base_m), min_m = float(header.min_m), max_m = float(header.max_m),
	}
