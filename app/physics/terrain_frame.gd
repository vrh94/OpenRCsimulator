extends RefCounted
## TG-06: the solid terrain's tangent plane under a body, as a local frame for contact laws written for flat ground
## at the datum (physics/hull_contact.gd). In the frame the plane is the datum and its normal points straight up, so
## a law's depth, normal force and ground friction act along and across the real slope. Body-axis velocities, rates
## and the laws' body-axis loads are unchanged by the frame; only position and attitude are re-expressed.
## The plane is exact for planar ground and differs from the curved surface by its curvature across the body.

const M := preload("res://physics/math3d.gd")
const RB := preload("res://physics/rigid_body.gd")


## The plane of the solid ground sample `ground` ([height_up_m, dh/dnorth, dh/deast], physics/ground_terrain.gd
## solid_sample) taken at field point (north, east): {q, origin}. `q` rotates NED vectors into the frame; `origin`
## is the ground point (NED) the frame turns about.
static func at(ground: PackedFloat64Array, north: float, east: float) -> Dictionary:
	var sn: float = ground[1]
	var se: float = ground[2]
	var length := sqrt(1.0 + sn * sn + se * se)
	# The up normal a = (-sn, -se, -1) / length in NED goes to b = (0, 0, -1): q = normalize(1 + a.b, a x b).
	var q := M.q_normalized(M.quat(1.0 + 1.0 / length, se / length, -sn / length, 0.0))
	return {q = q, origin = PackedFloat64Array([north, east, -ground[0]])}


## A rigid-body state in the frame. North and east stay about the origin, so field lookups by position still work.
static func state(frame: Dictionary, s: PackedFloat64Array) -> PackedFloat64Array:
	var origin: PackedFloat64Array = frame.origin
	var q: PackedFloat64Array = frame.q
	var out := s.duplicate()
	var rel := M.q_rotate(q, PackedFloat64Array([s[RB.POS] - origin[0], s[RB.POS + 1] - origin[1],
		s[RB.POS + 2] - origin[2]]))
	out[RB.POS] = origin[0] + rel[0]
	out[RB.POS + 1] = origin[1] + rel[1]
	out[RB.POS + 2] = rel[2]
	var attitude := M.q_mul(q, RB._att(s))
	for i in 4:
		out[RB.ATT + i] = attitude[i]
	return out


## A point of the frame back in field NED.
static func point_to_ned(frame: Dictionary, p: PackedFloat64Array) -> PackedFloat64Array:
	var origin: PackedFloat64Array = frame.origin
	var rel := M.q_rotate(M.q_conj(frame.q), PackedFloat64Array([p[0] - origin[0], p[1] - origin[1], p[2]]))
	return PackedFloat64Array([origin[0] + rel[0], origin[1] + rel[1], origin[2] + rel[2]])


## A vector of the frame back in field NED.
static func vector_to_ned(frame: Dictionary, v: PackedFloat64Array) -> PackedFloat64Array:
	return M.q_rotate(M.q_conj(frame.q), v)
