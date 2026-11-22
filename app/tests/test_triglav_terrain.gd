# TG-05/TG-06/TG-08: solid real terrain on the Triglav field: the provider against the baked grid, the sampler and
# airframe contact following it, flat fields unchanged, and an airplane parked and rolling on the sloped strip.
# Run: godot --headless --path . --script res://tests/test_triglav_terrain.gd
extends SceneTree

const FieldLoader = preload("res://data/field_loader.gd")
const GroundSurfaces = preload("res://physics/ground_surfaces.gd")
const Terrain = preload("res://physics/ground_terrain.gd")
const TerrainDem = preload("res://physics/terrain_dem.gd")
const TerrainFrame = preload("res://physics/terrain_frame.gd")
const HullContact = preload("res://physics/hull_contact.gd")
const Heightfield = preload("res://landscapes/triglav_tamar/heightfield.gd")
const Landscape = preload("res://landscapes/triglav_tamar/landscape.gd")
const Flight = preload("res://sim/flight_session.gd")
const TruckSession = preload("res://sim/ground_vehicle/session.gd")
const Catalog = preload("res://landscapes/catalog.gd")
const RotorcraftData = preload("res://physics/rotorcraft_data.gd")
const HeliGroundStart = preload("res://physics/rotorcraft/ground_start.gd")
const Obstacles = preload("res://landscapes/triglav_tamar/obstacles.gd")
const Collision = preload("res://sim/scenery_collision.gd")
const AircraftData = preload("res://physics/aircraft_data.gd")
const M = preload("res://physics/math3d.gd")
const RB = preload("res://physics/rigid_body.gd")
const FieldAir = preload("res://physics/field_air.gd")
const WindConfig = preload("res://physics/wind_config.gd")
const Atmosphere = preload("res://physics/atmosphere.gd")
const HeliSession = preload("res://sim/helicopter_flight_session.gd")
const QuadSession = preload("res://sim/multirotor/session.gd")
const FIELD := "res://landscapes/triglav_tamar/field.json"
const AIRCRAFT := "res://data/aircraft/jensen_ugly_stik_60.json"

var checks := 0
var failures := 0


func check(label: String, passed: bool, detail: String = "") -> void:
	checks += 1
	print(("ok   " if passed else "FAIL ") + label + ("" if passed or detail.is_empty() else " (%s)" % detail))
	if not passed:
		failures += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var loaded := FieldLoader.load_from(FIELD)
	check("the Triglav field loads with its terrain block", loaded.ok and loaded.field.has("terrain"), str(loaded.errors))
	if not loaded.ok:
		_finish()
		return
	var field: Dictionary = loaded.field
	check("the pilot spot is the landscape's render origin",
		is_equal_approx(float(field.terrain.origin_east), Heightfield.CORE_ORIGIN_EAST_M + Landscape.PILOT_CORE.x)
		and is_equal_approx(float(field.terrain.origin_north), Heightfield.CORE_ORIGIN_NORTH_M + Landscape.PILOT_CORE.y))
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIELD))
	raw.terrain.core = "user://elsewhere.json"
	check("a terrain path outside res:// is refused", not FieldLoader.validate(raw).ok)

	var table: Dictionary = GroundSurfaces.load_table()
	var built: Dictionary = GroundSurfaces.build(table.table, field)
	var airframe: Dictionary = GroundSurfaces.build_airframe(table.table, field)
	check("the surface tables build and carry the terrain", built.ok and airframe.ok and not str(built.terrain_identity).is_empty(),
		str(built.errors) + str(airframe.errors))
	var rects: PackedFloat64Array = built.rects
	var dem: RefCounted = Terrain.dem_for(rects)
	check("tyre and airframe tables select the same terrain", dem != null and Terrain.dem_for(airframe.rects) == dem)
	if dem == null:
		_finish()
		return

	# The provider against the grid.
	var core: RefCounted = Heightfield.load_grid("res://landscapes/triglav_tamar/terrain/core.json")
	var origin := Vector2(field.terrain.origin_east - Heightfield.CORE_ORIGIN_EAST_M,
		field.terrain.origin_north - Heightfield.CORE_ORIGIN_NORTH_M)
	var worst_node := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	for i in 200:
		var column := rng.randi_range(60, 3940)
		var row := rng.randi_range(60, 3940)
		var east: float = core.origin_east + column * core.spacing - origin.x
		var north: float = core.origin_north + row * core.spacing - origin.y
		worst_node = maxf(worst_node, absf(dem.height_m(north, east) - core.node_height(column, row)))
	check("the surface passes through every grid node", worst_node < 1e-6, str(worst_node))
	var worst_slope := 0.0
	var worst_step := 0.0
	for i in 300:
		var north := rng.randf_range(-2300.0, 6000.0)
		var east := rng.randf_range(-2300.0, 6000.0)
		var at: PackedFloat64Array = dem.sample(north, east)
		var d := 0.005
		var sn: float = (dem.sample(north + d, east)[0] - dem.sample(north - d, east)[0]) / (2.0 * d)
		var se: float = (dem.sample(north, east + d)[0] - dem.sample(north, east - d)[0]) / (2.0 * d)
		worst_slope = maxf(worst_slope, maxf(absf(sn - at[1]), absf(se - at[2])) / maxf(1.0, absf(at[1]) + absf(at[2])))
		# Real cliffs reach slopes near 80, so continuity is judged against the local slope.
		var step: float = absf(dem.sample(north + 0.001, east)[0] - at[0])
		worst_step = maxf(worst_step, step - (absf(at[1]) + 1.0) * 0.001 * 1.5)
	check("analytic slopes match finite differences", worst_slope < 2e-3, str(worst_slope))
	check("the surface is continuous: 1 mm moves stay within the local slope", worst_step < 1e-4, str(worst_step))
	var worst_band := 0.0
	for i in 200:
		var north := rng.randf_range(-2200.0, 5900.0)
		for edge_east: float in [1.0 - origin.x, 7999.0 - origin.x]:
			for offset: float in [0.0005, 48.0, 95.9995, 96.0005]:
				var east: float = edge_east + (offset if edge_east < 0.0 else -offset)
				var at: PackedFloat64Array = dem.sample(north, east)
				var step: float = absf(dem.sample(north, east + 0.001)[0] - at[0])
				worst_band = maxf(worst_band, step - (absf(at[2]) + 1.0) * 0.001 * 1.5)
	check("the core-to-ring blend is continuous", worst_band < 1e-4, str(worst_band))
	check("the field datum is the terrain under the pilot", absf(dem.sample(0.0, 0.0)[0]) < 1e-9)
	var hut_north: float = 145956.0 - field.terrain.origin_north
	var hut_east: float = 401150.0 - field.terrain.origin_east
	check("Dom v Tamarju stands at 1108 m (+-2 m) in the physics too",
		absf(dem.ground_ref_m + dem.sample(hut_north, hut_east)[0] - 1108.0) <= 2.0)

	# Two reference places: lower ground 2.1 km east (toward Podkoren) and the Ponce slopes 3 km south.
	var low := Vector2(0.0, 2100.0)
	var steep := Vector2(-3000.0, 500.0)
	var sunk: float = dem.sample(low.x, low.y)[0]
	var high: float = dem.sample(steep.x, steep.y)[0]
	check("the reference places lie below and far above the datum", sunk < -2.0 and high > 100.0, "%f %f" % [sunk, high])

	# The composed sampler.
	var composed: PackedFloat64Array = Terrain.sample_validated(low.x, low.y, rects)
	var bare: PackedFloat64Array = dem.sample(low.x, low.y)
	check("contact sampling adds the terrain under the microrelief",
		absf(composed[0] - bare[0]) <= Terrain.RELIEF_ROUGH_M + 1e-9, "%s %s" % [composed, bare])
	var west: float = dem.sample(-24.0, -50.0)[0]
	var east_end: float = dem.sample(-24.0, 50.0)[0]
	check("the strip is level within 1 % along its length", absf(east_end - west) < 1.0, "%f %f" % [west, east_end])
	var top := -INF
	for i in 2000:
		top = maxf(top, Terrain.sample_validated(rng.randf_range(-12000, 12000), rng.randf_range(-12000, 12000), rects)[0])
	check("the airborne skip bound covers the terrain", Terrain.max_height_validated(rects) >= top,
		"%f < %f" % [Terrain.max_height_validated(rects), top])
	var flat_raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://landscapes/green_paradise/field.json"))
	var flat: Dictionary = GroundSurfaces.build(table.table, FieldLoader.validate(flat_raw).field)
	check("a flat field has no terrain and keeps its relief bound",
		Terrain.dem_for(flat.rects) == null and Terrain.max_height_validated(flat.rects) == Terrain.RELIEF_ROUGH_M)
	_local_bounds(rects, dem, rng)
	check("a flat field's local bound is its relief bound", Terrain.max_height_near(flat.rects, 10.0, 20.0, 3.0)
		== Terrain.max_height_validated(flat.rects) and not Terrain.clear_of_solid_ground(flat.rects, 0.0, 0.0, 500.0, 1.0))

	# The tangent-plane frame.
	var frame: Dictionary = TerrainFrame.at(dem.sample(300.0, -400.0), 300.0, -400.0)
	var g: PackedFloat64Array = dem.sample(300.0, -400.0)
	var normal := Terrain.normal_from_up_slopes(g[1], g[2])
	var turned := M.q_rotate(frame.q, normal)
	check("the frame turns the terrain normal straight up", absf(turned[0]) < 1e-12 and absf(turned[1]) < 1e-12
		and absf(turned[2] + 1.0) < 1e-12, str(turned))
	var state := PackedFloat64Array()
	state.resize(RB.SIZE)
	state[RB.POS] = 302.0
	state[RB.POS + 1] = -401.0
	state[RB.POS + 2] = -g[0] - 3.0
	state[RB.ATT] = 1.0
	var framed := TerrainFrame.state(frame, state)
	var back := TerrainFrame.point_to_ned(frame, RB._slice3(framed, RB.POS))
	check("frame positions map back to NED", M.norm(M.sub(back, RB._slice3(state, RB.POS))) < 1e-9)
	check("a point above the slope is above the frame's datum", framed[RB.POS + 2] < 0.0)

	# Airframe contact follows the terrain: a 1 m box resting on the lower ground east of the field.
	var hull := PackedFloat64Array([0.5, 0.5, 0.2, 0.5, -0.5, 0.2, -0.5, 0.5, 0.2, -0.5, -0.5, 0.2])
	var prepared: Dictionary = HullContact.prepare(hull, 5.0,
		PackedFloat64Array([0.5, 0.5, 0.8, 0.0, 0.0, 0.0]), {}, airframe.rects)
	check("the test hull prepares", not prepared.is_empty())
	var rest := PackedFloat64Array()
	rest.resize(RB.SIZE)
	rest[RB.ATT] = 1.0
	rest[RB.POS] = low.x
	rest[RB.POS + 1] = low.y
	var under: float = sunk
	rest[RB.POS + 2] = -under - 0.2 + 0.01
	var pressed := HullContact.loads(rest, prepared)
	check("a hull 1 cm into the ground is pushed out", pressed.size() == 6 and pressed[2] < 0.0, str(pressed))
	rest[RB.POS + 2] = -under - 0.2 - 0.3
	check("a hull 30 cm above the ground is free", HullContact.loads(rest, prepared).is_empty())
	rest[RB.POS + 2] = -0.25
	check("the flat datum no longer holds a hull above sunken ground", HullContact.loads(rest, prepared).is_empty()
		and under < -1.0, str(under))
	var cliff := rest.duplicate()
	cliff[RB.POS] = steep.x
	cliff[RB.POS + 1] = steep.y
	cliff[RB.POS + 2] = -high + 0.5
	check("a hull inside a mountainside is in contact", not HullContact.contacts(cliff, cliff, prepared).is_empty()
		and high > 100.0, str(high))

	# Speed: the provider's cost per contact sample.
	var begin := Time.get_ticks_usec()
	var sink := 0.0
	for i in 20000:
		sink += Terrain.sample_validated(float(i % 200) * 0.37, float(i % 97) * 0.53, rects)[0]
	var per_sample := float(Time.get_ticks_usec() - begin) / 20000.0
	print("terrain sample %.2f us (sink %.1f)" % [per_sample, sink])
	check("a terrain contact sample costs under 25 us", per_sample < 25.0, "%.2f us" % per_sample)

	check("the landscape catalog lists Triglav with this field", Catalog.has("triglav_tamar")
		and Catalog.entry("triglav_tamar").field_path == FIELD)
	await _airplane(field)
	_truck(loaded, dem)
	_helicopter(field, dem)
	_obstacles(field, dem)
	_air_start(field, dem)
	_air(field, dem)
	_finish()


## An airplane starts on the sloped strip, sits, and rolls without crashing or sinking.
func _airplane(field: Dictionary) -> void:
	var s: Node = Flight.new()
	s.input_enabled = false
	s.crash_auto_restart = false
	s.soft_hull_contacts = true
	s.setup(AIRCRAFT)
	root.add_child(s)
	check("the airplane accepts the Triglav field", s.set_field(field))
	s.start_choice = Flight.START_RUNWAY
	s.reset()
	check("a runway start is admitted on the strip", s.is_flyable() and s.start_error.is_empty(), s.start_error)
	if not (s.is_flyable() and s.start_error.is_empty()):
		s.queue_free()
		return
	var start: PackedFloat64Array = s.sim.state.duplicate()
	var dem: RefCounted = Terrain.dem_for(s.ground_surfaces)
	var ground_up: float = dem.sample(start[RB.POS], start[RB.POS + 1])[0]
	print("start N %.1f E %.1f down %.3f, ground up %.3f" % [start[RB.POS], start[RB.POS + 1], start[RB.POS + 2], ground_up])
	check("the start stands on the terrain", absf(-start[RB.POS + 2] - ground_up) < 1.0,
		"%f vs %f" % [-start[RB.POS + 2], ground_up])
	s.sim.set_paused(false)
	for tick: int in 480:
		s._physics_process(s.sim.dt())
		s.sim.step()
		if not s.sim.fault_reason.is_empty() or not s.crash.is_empty(): break
	var parked: PackedFloat64Array = s.sim.state
	check("two seconds parked on the slope stay supported", s.sim.tick == 480 and s.crash.is_empty()
		and s.sim.fault_reason.is_empty(), "%s %s" % [s.sim.fault_reason, s.crash])
	var under: float = dem.sample(parked[RB.POS], parked[RB.POS + 1])[0]
	check("the parked airplane rests on the terrain", absf(-parked[RB.POS + 2] - under) < 1.0,
		"%f vs %f" % [-parked[RB.POS + 2], under])
	s.reset()
	s.sim.set_paused(false)
	var crashed := false
	for tick: int in 720:
		s.sim.inputs[3] = 1.0
		s._physics_process(s.sim.dt())
		s.sim.step()
		if not s.crash.is_empty() or not s.sim.fault_reason.is_empty():
			crashed = true
			break
	var rolled: PackedFloat64Array = s.sim.state
	print("after 3 s full power: N %.1f E %.1f down %.2f, ground up %.2f, speed %.1f m/s, crash %s" % [rolled[RB.POS],
		rolled[RB.POS + 1], rolled[RB.POS + 2], dem.sample(rolled[RB.POS], rolled[RB.POS + 1])[0],
		M.norm(RB._slice3(rolled, RB.VEL)), s.crash])
	check("a full-power take-off roll on the strip does not crash", not crashed, "%s %s" % [s.crash, s.sim.fault_reason])
	check("the roll moves the airplane along the ground", M.norm(M.sub(RB._slice3(rolled, RB.POS), RB._slice3(start, RB.POS))) > 5.0)
	s.queue_free()


## Option 4 (2026-11-22): local height and slope bounds let airborne skip tests work on terrain as on flat fields.
## They must never be below any sample within their square, on the core, its blend band, the ring and beyond.
func _local_bounds(rects: PackedFloat64Array, dem: RefCounted, rng: RandomNumberGenerator) -> void:
	var worst_height := INF
	var worst_slope := INF
	var tight := 0.0
	var count := 0
	for i in 6000:
		var scale: float = [400.0, 2500.0, 4200.0, 13000.0][i % 4]
		var north := rng.randf_range(-scale, scale)
		var east := rng.randf_range(-scale, scale)
		var radius: float = [0.0, 1.5, 6.0, 40.0][i % 4]
		var bound: PackedFloat64Array = dem.bounds_near(north, east, radius)
		for j in 6:
			var p := Vector2(north + rng.randf_range(-radius, radius), east + rng.randf_range(-radius, radius))
			var sample: PackedFloat64Array = dem.sample(p.x, p.y)
			worst_height = minf(worst_height, bound[0] - sample[0])
			worst_slope = minf(worst_slope, bound[1] - maxf(absf(sample[1]), absf(sample[2])))
			var composed: float = Terrain.sample_validated(p.x, p.y, rects)[0]
			worst_height = minf(worst_height, Terrain.max_height_near(rects, north, east, radius) - composed)
			tight += bound[0] - sample[0]
			count += 1
	print("local bounds: worst height margin %.4f m, worst slope margin %.4f, mean height margin %.1f m" % [
		worst_height, worst_slope, tight / count])
	check("the local height bound covers every sampled point", worst_height >= 0.0, str(worst_height))
	check("the local slope bound covers every sampled gradient", worst_slope >= 0.0, str(worst_slope))
	check("the local height bound follows the local ground", tight / count < 60.0, str(tight / count))
	# clear_of_solid_ground against the tangent frame it stands in for.
	var wrong := 0
	var cleared := 0
	for i in 3000:
		var north := rng.randf_range(-3000.0, 3000.0)
		var east := rng.randf_range(-3000.0, 3000.0)
		var ground: PackedFloat64Array = Terrain.solid_sample(rects, north, east)
		var altitude: float = ground[0] + rng.randf_range(-2.0, 30.0)
		var reach := rng.randf_range(0.2, 3.0)
		if Terrain.clear_of_solid_ground(rects, north, east, altitude, reach):
			cleared += 1
			var framed: PackedFloat64Array = TerrainFrame.state(TerrainFrame.at(ground, north, east), _pose(north, east, -altitude))
			if -framed[RB.POS + 2] <= reach:
				wrong += 1
	var high := 0
	for i in 1000:
		var north := rng.randf_range(-3000.0, 3000.0)
		var east := rng.randf_range(-3000.0, 3000.0)
		var ground: float = Terrain.solid_sample(rects, north, east)[0]
		if Terrain.clear_of_solid_ground(rects, north, east, ground + rng.randf_range(100.0, 200.0), 2.0):
			high += 1
	print("clear_of_solid_ground: %d of 3000 near the ground cleared, %d of 1000 at 100-200 m" % [cleared, high])
	check("terrain clearance never clears a body within its reach of the tangent plane", wrong == 0, str(wrong))
	check("terrain clearance clears bodies 100-200 m above the ground", high > 900, str(high))
	check("terrain clearance never clears over a levelled pad", not Terrain.clear_of_solid_ground(rects, -12.0, 0.0, 400.0, 1.0))


## The X-Maxx drives off on the Rateče meadow and stays on its wheels on the real ground.
func _truck(loaded: Dictionary, dem: RefCounted) -> void:
	var s: Node = TruckSession.new()
	root.add_child(s)
	var ready: bool = s.prepare_airfield(loaded, {}, {}, "x-maxx-8s")
	check("the truck prepares on the Triglav field", ready)
	if not ready:
		s.free()
		return
	var neutral := {"throttle": 0.0, "steering": 0.0, "brake": 0.0, "reverse": false, "armed": true}
	s.tick_once(neutral)
	s.resume()
	var lowest := INF
	var highest := -INF
	var start: PackedFloat64Array = s.state_snapshot()
	var drive := {"throttle": 0.35, "steering": 0.15, "brake": 0.0, "reverse": false, "armed": true}
	var worst_gap := 0.0
	var upright := true
	for i in 240 * 8:
		s.tick_once(drive)
		var st: PackedFloat64Array = s.state_snapshot()
		var under: float = dem.sample(st[0], st[1])[0]
		lowest = minf(lowest, under)
		highest = maxf(highest, under)
		worst_gap = maxf(worst_gap, absf(-st[2] - under))
		var up := M.q_rotate(M.quat(st[6], st[7], st[8], st[9]), PackedFloat64Array([0.0, 0.0, -1.0]))
		upright = upright and up[2] < -0.5
	var end: PackedFloat64Array = s.state_snapshot()
	var travelled := Vector2(end[0] - start[0], end[1] - start[1]).length()
	print("truck: start N %.1f E %.1f, travelled %.1f m, worst CG height above terrain %.2f m" % [start[0], start[1],
		travelled, worst_gap])
	check("the truck's path crosses changing ground (so following it matters)", highest - lowest > 0.2,
		"%.2f m" % (highest - lowest))
	check("the truck drives off across the meadow", travelled > 20.0, str(travelled))
	check("the truck stays upright on its wheels", upright)
	check("the truck's body stays within 1 m of the terrain", worst_gap < 1.0, str(worst_gap))
	s.free()


## The research helicopter rests on its pad on the real ground.
func _helicopter(field: Dictionary, dem: RefCounted) -> void:
	var aircraft: Dictionary = RotorcraftData.load_file("res://data/aircraft/xcell_60_research.json")
	var result: Dictionary = HeliGroundStart.resolve(field, aircraft)
	check("the helicopter pad resolves a resting pose on the terrain", bool(result.get("ok", false)), str(result.get("reason", "")))
	if bool(result.get("ok", false)):
		var state: PackedFloat64Array = result.state
		var under: float = dem.sample(state[0], state[1])[0]
		print("helicopter: pad N %.1f E %.1f, CG %.2f m above the terrain (terrain %.2f m)" % [state[0], state[1],
			-state[2] - under, under])
		check("the helicopter rests on the terrain, not the datum", absf(-state[2] - under) < 1.0 and result.contact_count == 4)


## TG-07: the surveyed trees and buildings near the pilot are solid, standing on the terrain.
func _obstacles(field: Dictionary, dem: RefCounted) -> void:
	var began := Time.get_ticks_msec()
	var built: Dictionary = Catalog.collision_world("triglav_tamar", field)
	var build_ms := Time.get_ticks_msec() - began
	check("the Triglav obstacle world builds", bool(built.get("ok", false)), str(built.get("errors", [])))
	if not bool(built.get("ok", false)):
		return
	var world: Dictionary = built.world
	var trunks: Array[Dictionary] = []
	var buildings := 0
	var farthest := 0.0
	var farthest_tree := 0.0
	var worst_root := 0.0
	for proxy: Dictionary in world.proxies:
		farthest = maxf(farthest, Vector2(proxy.north, proxy.east).length())
		if proxy.kind == "tree_trunk":
			trunks.append(proxy)
			farthest_tree = maxf(farthest_tree, Vector2(proxy.north, proxy.east).length())
			var root_up: float = -float(proxy.bounds_down_max)
			worst_root = maxf(worst_root, absf(root_up - float(dem.sample(proxy.north, proxy.east)[0])))
		elif proxy.kind == "building":
			buildings += 1
	print("obstacles: %d proxies (%d trunks, %d building blocks), %d bytes, built in %d ms; farthest %.0f m; worst trunk root %.2f m from the terrain"
		% [world.proxies.size(), trunks.size(), buildings, var_to_bytes(world).size(), build_ms, farthest, worst_root])
	check("trees and buildings near the pilot are solid", trunks.size() > 5000 and buildings > 100)
	check("only trees within the solid radius are in the world", farthest_tree <= Obstacles.RADIUS_M + 1e-3, str(farthest_tree))
	check("buildings reaching into the radius are whole, nothing far beyond", farthest < Obstacles.RADIUS_M + 150.0, str(farthest))
	check("every solid tree stands on the solid terrain (within 1.5 m)", worst_root < 1.5, str(worst_root))
	var again: Dictionary = Catalog.collision_world("triglav_tamar", field)
	check("a rebuilt world has the same identity", str(again.world.identity) == str(world.identity))
	var aircraft: Dictionary = AircraftData.load_file(AIRCRAFT)
	var hull: PackedFloat64Array = aircraft.model.crash_hull
	var inertia: PackedFloat64Array = aircraft.model.inertia
	var mass := float(aircraft.model.mass_kg)
	var trunk: Dictionary = trunks[trunks.size() / 2]
	var mid := float(trunk.bounds_down_max) - 1.0
	var into := Collision.first_hit(_pose(trunk.north - 3.0, trunk.east, mid), _pose(trunk.north + 3.0, trunk.east, mid),
		hull, world, 1, mass, inertia)
	check("an airplane flying into a trunk 1 m above its root hits it", into != null)
	var above_top := float(trunk.bounds_down_min) - 200.0
	var over := Collision.first_hit(_pose(trunk.north - 3.0, trunk.east, above_top),
		_pose(trunk.north + 3.0, trunk.east, above_top), hull, world, 1, mass, inertia)
	check("an airplane 200 m over the forest hits nothing", over == null)
	var s: Node = Flight.new()
	s.input_enabled = false
	s.setup(AIRCRAFT)
	root.add_child(s)
	check("a flight session accepts the Triglav obstacle world", s.set_field(field) and s.set_collision_world(world))
	s.free()


## An air start's altitude is above the ground under it, and the trimmed glide leaves it clear of the hills.
func _air_start(field: Dictionary, dem: RefCounted) -> void:
	var s: Node = Flight.new()
	s.input_enabled = false
	s.crash_auto_restart = false
	s.setup(AIRCRAFT)
	root.add_child(s)
	check("the airplane takes the Triglav field for an air start", s.set_field(field))
	s.start_choice = Flight.START_AIRBORNE
	s.reset()
	var state: PackedFloat64Array = s.sim.state
	var under: float = dem.sample(state[RB.POS], state[RB.POS + 1])[0]
	var stored: float = -float(s.start.state[RB.POS + 2])
	print("air start: N %.1f E %.1f, %.1f m above the ground (authored %.1f m)" % [state[RB.POS], state[RB.POS + 1],
		-state[RB.POS + 2] - under, stored])
	check("the air start stands its authored altitude above the ground", absf(-state[RB.POS + 2] - under - stored) < 1e-6)
	s.sim.set_paused(false)
	for tick: int in 240 * 5:
		s._physics_process(s.sim.dt())
		s.sim.step()
		if not s.crash.is_empty(): break
	check("five seconds of trimmed flight from the air start stay clear", s.crash.is_empty(), str(s.crash))
	s.queue_free()


## Owner decision 2026-11-21: the Triglav field flies in the air at its real height (physics/field_air.gd).
func _air(field: Dictionary, dem: RefCounted) -> void:
	var elevation := FieldAir.elevation_m(field)
	print("field elevation %.1f m" % elevation)
	check("the field elevation is the surveyed ground under the pilot", absf(elevation - dem.ground_ref_m) <= 0.05
		and elevation > 800.0 and elevation < 900.0, str(elevation))
	var flat: Dictionary = FieldLoader.load_from().field
	check("a flat field keeps sea-level air", FieldAir.elevation_m(flat) == 0.0
		and var_to_bytes(FieldAir.weather(WindConfig.defaults(), flat)) == var_to_bytes(WindConfig.defaults()))
	var calm: Dictionary = FieldAir.weather(WindConfig.defaults(), field)
	var checked: Dictionary = WindConfig.validate(calm)
	var air: Dictionary = WindConfig.atmosphere(checked.config) if checked.ok else {}
	var isa: Dictionary = Atmosphere.standard_column(elevation)
	print("calm reference air on Triglav: rho %.4f kg/m3 (ISA %.4f), density altitude %.0f m" % [
		float(air.get("rho_kgm3", NAN)), float(isa.rho_kgm3), float(air.get("density_altitude_m", NAN))])
	check("the default air becomes the standard atmosphere at the field", checked.ok
		and absf(float(air.rho_kgm3) - float(isa.rho_kgm3)) < 0.001 and absf(float(air.density_altitude_m) - elevation) < 15.0,
		str(checked.errors))
	check("the wind of the choice is kept", float(calm.speed_mps) == 0.0 and not WindConfig.has_turbulence(calm))
	check("the field air is idempotent", var_to_bytes(FieldAir.weather(calm, field)) == var_to_bytes(calm))
	var hot: Dictionary = FieldAir.weather(WindConfig.preset("hot-high"), field)
	check("a custom choice keeps its temperature and takes the field elevation", float(hot.temperature_c) == 35.0
		and float(hot.field_elevation_m) == elevation)
	var column: Dictionary = FieldAir.weather(WindConfig.preset("standard-column"), field)
	check("a standard column starts at the field elevation", WindConfig.validate(column).ok
		and float(column.field_elevation_m) == elevation)

	var plane: Node = Flight.new()
	plane.setup(AIRCRAFT)
	root.add_child(plane)
	var plane_ok: bool = plane.set_field(field) and plane.setup_weather(calm)
	check("the airplane flies in the field air", plane_ok and absf(plane.environment.air_density(0.0) - float(isa.rho_kgm3)) < 0.001,
		plane.weather_error)
	plane.queue_free()
	check("the helicopter admits the field air", bool(HeliSession.validate_weather_selection(calm).ok),
		str(HeliSession.validate_weather_selection(calm).error))
	var quad: Node = QuadSession.new()
	root.add_child(quad)
	var quad_ok: bool = quad.prepare(field, {start = "air", altitude_m = 10.0})
	check("the FPV quad flies in the field air", quad_ok and absf(quad.environment.air_density(0.0) - float(isa.rho_kgm3)) < 0.001,
		str(quad.get("load_error")))
	quad.queue_free()


func _pose(north: float, east: float, down: float) -> PackedFloat64Array:
	return RB.make_state(PackedFloat64Array([north, east, down]), PackedFloat64Array([20.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0, 0.0]), PackedFloat64Array([0.0, 0.0, 0.0]))


func _finish() -> void:
	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
