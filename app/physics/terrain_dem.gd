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
## Local height bounds (max_up_near) are kept per square block of this size, computed on first use.
const BOUND_BLOCK_M := 32.0
## A Catmull-Rom patch exceeds its 4 x 4 nodes by at most this fraction of their range: per axis the positive
## weights sum to 1 + t(1-t)/2 <= 1.125 and the negative ones to 0.125, so in 2D the positive products sum to at most
## 1.125^2 + 0.125^2 = 1.28125 and h <= min + 1.28125 (max - min).
const BICUBIC_OVERSHOOT := 0.28125
## Absolute slack for floating-point rounding in the samplers (heights are ~1e3 m, rounding ~1e-12 m).
const BOUND_SLACK_M := 0.001

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

var _bounds: Dictionary = {}   # Vector2i block -> [height bound (m above ground_ref_m), slope bound]
var _bounds_mutex := Mutex.new()

var _smooth: Dictionary = {}   # Vector3i(column, row, spacing) -> mean height of the box around that node
var _smooth_mutex := Mutex.new()

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


## A bound on sample()[0] over the square of half-width `radius` around field point (north, east): never below the
## height of any point in it, and usually within a few metres of the highest. Deterministic for a given grid.
func max_up_near(north: float, east: float, radius: float) -> float:
	return bounds_near(north, east, radius)[0]


## [height bound, slope bound] over the square of half-width `radius` around (north, east): no sample()[0] in it is
## higher than the first, and neither |dh/dnorth| nor |dh/deast| is larger than the second.
func bounds_near(north: float, east: float, radius: float) -> PackedFloat64Array:
	if not (radius >= 0.0) or not is_finite(north) or not is_finite(east) or not is_finite(radius):
		return PackedFloat64Array([max_up_m + BOUND_SLACK_M, INF])
	var bx0 := floori((east - radius) / BOUND_BLOCK_M)
	var bx1 := floori((east + radius) / BOUND_BLOCK_M)
	var by0 := floori((north - radius) / BOUND_BLOCK_M)
	var by1 := floori((north + radius) / BOUND_BLOCK_M)
	if (bx1 - bx0 + 1) * (by1 - by0 + 1) > 64:
		return PackedFloat64Array([max_up_m + BOUND_SLACK_M, INF])
	var top := -INF
	var slope := 0.0
	for by in range(by0, by1 + 1):
		for bx in range(bx0, bx1 + 1):
			var block := _block_bound(Vector2i(bx, by))
			top = maxf(top, block[0])
			slope = maxf(slope, block[1])
	return PackedFloat64Array([top, slope])


func _block_bound(block: Vector2i) -> PackedFloat64Array:
	_bounds_mutex.lock()
	var known: Variant = _bounds.get(block)
	_bounds_mutex.unlock()
	if known != null:
		return known
	var xa := block.x * BOUND_BLOCK_M
	var ya := block.y * BOUND_BLOCK_M
	var xb := xa + BOUND_BLOCK_M
	var yb := ya + BOUND_BLOCK_M
	# The ring's bilinear patch (also the far field, where its nodes and fractions clamp) stays within its 4 nodes,
	# and each slope component is one node difference over a spacing.
	var ring := _node_range(_r_data, _r_cols, _r_rows, floori((xa - _r_x0) / _r_spacing),
		floori((xb - _r_x0) / _r_spacing) + 1, floori((ya - _r_y0) / _r_spacing), floori((yb - _r_y0) / _r_spacing) + 1)
	var top := (ring[0] - _r_ref) * _r_step
	var low := (ring[1] - _r_ref) * _r_step
	var slope := maxi(ring[2], ring[3]) * _r_step / _r_spacing
	# Inside the core the bicubic patch (blended toward the ring near its edge) spans one more node each side. Summed
	# by parts, a Catmull-Rom derivative is a combination of adjacent node differences with absolute weights summing to
	# at most 1.5, taken across rows (or columns) whose weights sum in absolute value to at most 1.25.
	if xb > _c_x0 and xa < _c_x1 and yb > _c_y0 and ya < _c_y1:
		var core := _node_range(_c_data, _c_cols, _c_rows, floori((xa - _c_x0) / _c_spacing) - 1,
			floori((xb - _c_x0) / _c_spacing) + 2, floori((ya - _c_y0) / _c_spacing) - 1,
			floori((yb - _c_y0) / _c_spacing) + 2)
		var spread := float(core[0] - core[1])
		var fine_top := (core[0] + BICUBIC_OVERSHOOT * spread - _c_ref) * _c_step
		var fine_low := (core[1] - BICUBIC_OVERSHOOT * spread - _c_ref) * _c_step
		slope = maxf(slope, 1.875 * maxi(core[2], core[3]) * _c_step / _c_spacing)
		# Within BLEND_M of the core edge the blend weight's slope (at most 1.5 / BLEND_M) multiplies fine - ring.
		var inset := minf(minf(xa - _c_x0, _c_x1 - xb), minf(ya - _c_y0, _c_y1 - yb))
		if inset < BLEND_M:
			slope += 1.5 / BLEND_M * (maxf(top, fine_top) - minf(low, fine_low))
		top = maxf(top, fine_top)
	var bound := PackedFloat64Array([top + BOUND_SLACK_M, slope * (1.0 + 1e-9) + 1e-9])
	_bounds_mutex.lock()
	_bounds[block] = bound
	_bounds_mutex.unlock()
	return bound


## [max, min, largest step between column neighbours, largest step between row neighbours] of the grid nodes in
## columns c0..c1 and rows r0..r1, clamped to the grid.
static func _node_range(data: PackedByteArray, cols: int, rows: int, c0: int, c1: int, r0: int, r1: int) -> PackedInt32Array:
	c0 = clampi(c0, 0, cols - 1)
	c1 = clampi(c1, 0, cols - 1)
	r0 = clampi(r0, 0, rows - 1)
	r1 = clampi(r1, 0, rows - 1)
	var high := 0
	var low := 65535
	var step_x := 0
	var step_y := 0
	for r in range(r0, r1 + 1):
		var at := (r * cols + c0) * 2
		var left := data.decode_u16(at)
		for c in range(c0, c1 + 1):
			var v := data.decode_u16(at)
			high = maxi(high, v)
			low = mini(low, v)
			step_x = maxi(step_x, absi(v - left))
			left = v
			if r < r1:
				step_y = maxi(step_y, absi(data.decode_u16(at + cols * 2) - v))
			at += 2
	return PackedInt32Array([high, low, step_x, step_y])


## [height, dh/dnorth, dh/deast] of the terrain smoothed at `spacing` metres (32-256): a Catmull-Rom patch through
## nodes every `spacing` metres, each the mean of the 16 m ring surface over a spacing-wide box around it (5 x 5
## samples). Features narrower than about the spacing vanish; the slope is continuous. For flow over the terrain
## (physics/wind_spatial_field.gd terrain_flow), not for contact.
func smooth_sample(north: float, east: float, spacing: float) -> PackedFloat64Array:
	var u := east / spacing
	var v := north / spacing
	var c := floori(u)
	var r := floori(v)
	var tx := u - c
	var ty := v - r
	var tx2 := tx * tx
	var ty2 := ty * ty
	# Catmull-Rom weights (w) and their derivatives (d), written out as in _bicubic.
	var wx0 := 0.5 * (-tx2 * tx + 2.0 * tx2 - tx)
	var wx1 := 0.5 * (3.0 * tx2 * tx - 5.0 * tx2 + 2.0)
	var wx2 := 0.5 * (-3.0 * tx2 * tx + 4.0 * tx2 + tx)
	var wx3 := 0.5 * (tx2 * tx - tx2)
	var dx0 := 0.5 * (-3.0 * tx2 + 4.0 * tx - 1.0)
	var dx1 := 0.5 * (9.0 * tx2 - 10.0 * tx)
	var dx2 := 0.5 * (-9.0 * tx2 + 8.0 * tx + 1.0)
	var dx3 := 0.5 * (3.0 * tx2 - 2.0 * tx)
	var p := _smooth_patch(c, r, int(spacing), spacing)
	var r0 := wx0 * p[0] + wx1 * p[1] + wx2 * p[2] + wx3 * p[3]
	var r1 := wx0 * p[4] + wx1 * p[5] + wx2 * p[6] + wx3 * p[7]
	var r2 := wx0 * p[8] + wx1 * p[9] + wx2 * p[10] + wx3 * p[11]
	var r3 := wx0 * p[12] + wx1 * p[13] + wx2 * p[14] + wx3 * p[15]
	var s0 := dx0 * p[0] + dx1 * p[1] + dx2 * p[2] + dx3 * p[3]
	var s1 := dx0 * p[4] + dx1 * p[5] + dx2 * p[6] + dx3 * p[7]
	var s2 := dx0 * p[8] + dx1 * p[9] + dx2 * p[10] + dx3 * p[11]
	var s3 := dx0 * p[12] + dx1 * p[13] + dx2 * p[14] + dx3 * p[15]
	var wy0 := 0.5 * (-ty2 * ty + 2.0 * ty2 - ty)
	var wy1 := 0.5 * (3.0 * ty2 * ty - 5.0 * ty2 + 2.0)
	var wy2 := 0.5 * (-3.0 * ty2 * ty + 4.0 * ty2 + ty)
	var wy3 := 0.5 * (ty2 * ty - ty2)
	var dy0 := 0.5 * (-3.0 * ty2 + 4.0 * ty - 1.0)
	var dy1 := 0.5 * (9.0 * ty2 - 10.0 * ty)
	var dy2 := 0.5 * (-9.0 * ty2 + 8.0 * ty + 1.0)
	var dy3 := 0.5 * (3.0 * ty2 - 2.0 * ty)
	return PackedFloat64Array([wy0 * r0 + wy1 * r1 + wy2 * r2 + wy3 * r3,
		(dy0 * r0 + dy1 * r1 + dy2 * r2 + dy3 * r3) / spacing,
		(wy0 * s0 + wy1 * s1 + wy2 * s2 + wy3 * s3) / spacing])


## The 4 × 4 smoothed nodes around cell (column, row), row-major from (column - 1, row - 1); cached per cell so a
## sample takes one lookup. The values are the cached nodes themselves, so samples are unchanged.
func _smooth_patch(column: int, row: int, key_spacing: int, spacing: float) -> PackedFloat64Array:
	var key := Vector3i(column, row, -key_spacing)
	_smooth_mutex.lock()
	var known: Variant = _smooth.get(key)
	_smooth_mutex.unlock()
	if known != null:
		return known
	var patch := PackedFloat64Array()
	patch.resize(16)
	for j in 4:
		for i in 4:
			patch[j * 4 + i] = _smooth_node(column - 1 + i, row - 1 + j, key_spacing, spacing)
	_smooth_mutex.lock()
	_smooth[key] = patch
	_smooth_mutex.unlock()
	return patch


func _smooth_node(column: int, row: int, key_spacing: int, spacing: float) -> float:
	var key := Vector3i(column, row, key_spacing)
	_smooth_mutex.lock()
	var known: Variant = _smooth.get(key)
	_smooth_mutex.unlock()
	if known != null:
		return known
	var x := column * spacing
	var y := row * spacing
	var total := 0.0
	for j in 5:
		for i in 5:
			total += _bilinear(x + (i - 2) * spacing * 0.25, y + (j - 2) * spacing * 0.25)[0]
	var value := total / 25.0
	_smooth_mutex.lock()
	_smooth[key] = value
	_smooth_mutex.unlock()
	return value


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
