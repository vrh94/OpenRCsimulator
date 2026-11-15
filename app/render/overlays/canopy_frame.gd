## FPV-8: the cockpit view's canopy frame on screen: a dark frame and instrument coaming around a rounded glass
## opening, fixed to the airframe, so a head turn (right-drag or head tracking) slides it the other way across the
## picture. Drawn over the 3D picture and under the route's panels. Presentation only; no aircraft declares a
## cockpit, so the shape is one generic glider-like canopy for every fixed-wing model.
extends CanvasLayer

## Above the lens picture (FpvLens LAYER −100) and below the FPV OSD (−90, never shown with the cockpit).
const LAYER := -95
## The glass opening, as shares of the window: centre, half extents, and the superellipse exponent (2 = ellipse,
## larger = squarer corners). The bottom edge is the instrument coaming over the nose.
const CENTRE := Vector2(0.5, 0.40)
const HALF := Vector2(0.49, 0.47)
const SQUARENESS := 3.2
## How far (share of the window) a head turn may slide the frame; past it the frame stays at the edge.
const MAX_SHIFT := Vector2(0.12, 0.35)
## The canopy wraps round the pilot's head, so a sideways look meets more glass, not the frame: the frame slides
## this share of a turn sideways; up and down it slides fully (the coaming is fixed ahead of the eye).
const PARALLAX_X := 0.35
const SEGMENTS := 96
const FRAME_COLOUR := Color(0.07, 0.075, 0.085)
const EDGE_COLOUR := Color(0.32, 0.33, 0.35)
const EDGE_WIDTH_SHARE := 0.004
## A thin centre bow across the top of the glass, like a two-piece canopy.
const BOW_HALF_WIDTH_SHARE := 0.006

var _shift := Vector2.ZERO
var _canvas: Control


func _init() -> void:
	name = "CanopyFrame"
	layer = LAYER
	visible = false
	_canvas = Control.new()
	_canvas.name = "CanopyCanvas"
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.draw.connect(_draw_frame)
	add_child(_canvas)


## head_deg: the head-look (yaw right +, pitch up +, degrees); hfov_deg: the cockpit eye's horizontal field of view.
func set_head(head_deg: Vector2, hfov_deg: float) -> void:
	var shift := shift_for(head_deg, hfov_deg)
	if not shift.is_equal_approx(_shift):
		_shift = shift
		_canvas.queue_redraw()


## The frame's slide (share of the window) for a head turn: a pinhole projection of the turn, clamped.
static func shift_for(head_deg: Vector2, hfov_deg: float) -> Vector2:
	var half_tan := tan(deg_to_rad(clampf(hfov_deg, 10.0, 170.0)) * 0.5)
	var share_per_rad := 0.5 / half_tan # of the window width, near the centre
	var x := -PARALLAX_X * share_per_rad * tan(deg_to_rad(clampf(head_deg.x, -80.0, 80.0)))
	var y := share_per_rad * tan(deg_to_rad(clampf(head_deg.y, -80.0, 80.0)))
	return Vector2(clampf(x, -MAX_SHIFT.x, MAX_SHIFT.x), clampf(y, -MAX_SHIFT.y, MAX_SHIFT.y))


## The glass opening's outline in pixels (SEGMENTS points, counter-clockwise from the right).
static func opening(size: Vector2, shift: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var centre := (CENTRE + shift) * size
	var half := HALF * size
	for i in SEGMENTS:
		var a := TAU * i / SEGMENTS
		var c := cos(a)
		var s := sin(a)
		out.append(centre + Vector2(half.x * signf(c) * pow(absf(c), 2.0 / SQUARENESS),
			half.y * signf(s) * pow(absf(s), 2.0 / SQUARENESS)))
	return out


## Whether a window pixel is behind the frame (outside the glass).
static func covers(size: Vector2, shift: Vector2, pixel: Vector2) -> bool:
	var p := (pixel / size - CENTRE - shift) / HALF
	return pow(absf(p.x), SQUARENESS) + pow(absf(p.y), SQUARENESS) > 1.0


func _draw_frame() -> void:
	var size := _canvas.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var glass := opening(size, _shift)
	var centre := (CENTRE + _shift) * size
	var reach := size.length() * 2.0 # far past every window edge
	# The frame: one quad per outline segment, from the glass edge out along the ray from the centre.
	for i in glass.size():
		var a := glass[i]
		var b := glass[(i + 1) % glass.size()]
		var a_out := centre + (a - centre).normalized() * reach
		var b_out := centre + (b - centre).normalized() * reach
		_canvas.draw_colored_polygon(PackedVector2Array([a, b, b_out, a_out]), FRAME_COLOUR)
	var edge := maxf(1.0, EDGE_WIDTH_SHARE * size.y)
	var closed := glass.duplicate()
	closed.append(glass[0])
	_canvas.draw_polyline(closed, EDGE_COLOUR, edge, true)
	# The centre bow, from the top of the glass down a little way, as on a two-piece canopy.
	var top := centre + Vector2(0.0, -HALF.y * size.y)
	var bow := BOW_HALF_WIDTH_SHARE * size.x
	_canvas.draw_rect(Rect2(top.x - bow, top.y, bow * 2.0, HALF.y * size.y * 0.35), FRAME_COLOUR)
	_canvas.draw_line(Vector2(top.x - bow, top.y), Vector2(top.x - bow, top.y + HALF.y * size.y * 0.35), EDGE_COLOUR, edge)
	_canvas.draw_line(Vector2(top.x + bow, top.y), Vector2(top.x + bow, top.y + HALF.y * size.y * 0.35), EDGE_COLOUR, edge)


func evidence() -> Dictionary:
	return {visible = visible, shift = [snappedf(_shift.x, 0.001), snappedf(_shift.y, 0.001)]}
