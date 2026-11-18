extends RefCounted
## An `openrc-heightfield v1` grid (research/triglav/TG-02/bake_terrain.py): gzip of little-endian uint16 heights,
## height_m = base_m + value * step_m, rows south to north, columns west to east, node (0, 0) at the origin.
## Coordinates here are metres east and north of the Triglav core's south-west corner (D96/TM E 399000, N 144000).

const FORMAT := "openrc-heightfield v1"
const CORE_ORIGIN_EAST_M := 399000.0
const CORE_ORIGIN_NORTH_M := 144000.0

var columns: int = 0
var rows: int = 0
var origin_east: float = 0.0   ## of node (0, 0), in the core frame
var origin_north: float = 0.0
var spacing: float = 1.0
var base_m: float = 0.0
var step_m: float = 1.0
var min_m: float = 0.0
var max_m: float = 0.0
var data: PackedByteArray = PackedByteArray()
var error: String = ""


## Loads and verifies a grid; `error` is non-empty on failure (missing file, wrong format, size or checksum).
static func load_grid(json_path: String) -> RefCounted:
	var grid: RefCounted = new()
	if not FileAccess.file_exists(json_path):
		grid.error = "heightfield: missing %s" % json_path
		return grid
	var text := FileAccess.get_file_as_string(json_path)
	var header: Variant = JSON.parse_string(text)
	if not (header is Dictionary) or str(header.get("format", "")) != FORMAT:
		grid.error = "heightfield: %s is not an %s header" % [json_path, FORMAT]
		return grid
	var packed := FileAccess.get_file_as_bytes(json_path.get_base_dir().path_join(str(header.data)))
	if packed.is_empty():
		grid.error = "heightfield: missing data for %s" % json_path
		return grid
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(packed)
	if hashing.finish().hex_encode() != str(header.data_sha256):
		grid.error = "heightfield: checksum mismatch for %s" % json_path
		return grid
	grid.columns = int(header.columns)
	grid.rows = int(header.rows)
	grid.data = packed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if grid.data.size() != grid.columns * grid.rows * 2:
		grid.error = "heightfield: %s holds %d bytes, expected %d" % [json_path, grid.data.size(), grid.columns * grid.rows * 2]
		return grid
	grid.origin_east = float(header.origin_east_m) - CORE_ORIGIN_EAST_M
	grid.origin_north = float(header.origin_north_m) - CORE_ORIGIN_NORTH_M
	grid.spacing = float(header.spacing_m)
	grid.base_m = float(header.base_m)
	grid.step_m = float(header.step_m)
	grid.min_m = float(header.min_m)
	grid.max_m = float(header.max_m)
	return grid


func ok() -> bool:
	return error.is_empty() and not data.is_empty()


func node_height(column: int, row: int) -> float:
	column = clampi(column, 0, columns - 1)
	row = clampi(row, 0, rows - 1)
	return base_m + data.decode_u16((row * columns + column) * 2) * step_m


## Bilinear height at a point of the core frame; clamped to the edge outside the grid.
func height_at(east: float, north: float) -> float:
	var x := (east - origin_east) / spacing
	var y := (north - origin_north) / spacing
	var c := floori(x)
	var r := floori(y)
	var fx := clampf(x - c, 0.0, 1.0)
	var fy := clampf(y - r, 0.0, 1.0)
	var h00 := node_height(c, r)
	var h10 := node_height(c + 1, r)
	var h01 := node_height(c, r + 1)
	var h11 := node_height(c + 1, r + 1)
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


func contains(east: float, north: float, margin: float = 0.0) -> bool:
	return east >= origin_east + margin and north >= origin_north + margin \
		and east <= origin_east + (columns - 1) * spacing - margin and north <= origin_north + (rows - 1) * spacing - margin


## The raw grid as a two-channel texture: red the low byte, green the high byte (read with texelFetch).
func texture() -> ImageTexture:
	return ImageTexture.create_from_image(Image.create_from_data(columns, rows, false, Image.FORMAT_RG8, data))
