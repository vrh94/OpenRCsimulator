# Option 5 (2026-11-22): the Rateče meadow race course on the Triglav field. The course prepares on the surveyed
# terrain; its gates, pad and the straight lines between gates keep clear of the surveyed trees and buildings (which are
# not field-listed objects, so the track's own clearance check does not see them); the test_race_session scripted pilot,
# holding each gate's height above the local ground, flies three valid laps with no crash; and the FPV quad activity
# offers the course on Triglav while Club field keeps its own.
# Run: godot --headless --path . --audio-driver Dummy --script res://tests/test_triglav_race.gd
extends SceneTree

const RB := preload("res://physics/rigid_body.gd")
const Fixtures := preload("res://tests/mr_fixtures.gd")
const RaceTest := preload("res://tests/test_race_session.gd")
const Session := preload("res://sim/multirotor/session.gd")
const FieldLoader := preload("res://data/field_loader.gd")
const CollisionSetup := preload("res://scenery/collision_setup.gd")
const Director := preload("res://sim/race/race_director.gd")
const RaceModel := preload("res://sim/race/race_model.gd")
const Scene := preload("res://vehicles/multirotor/multirotor_scene.gd")

const FIELD := "res://landscapes/triglav_tamar/field.json"
const TRACK := "res://data/race/tracks/openrc-ratece-meadow-1.json"
## Horizontal clearance kept from every surveyed tree and building: gate frames and the pad.
const GATE_CLEARANCE_M := 4.0
## Horizontal clearance of the straight line between consecutive gates (the racing line) from anything taller than
## the lower of the two gates' tops.
const LINE_CLEARANCE_M := 3.0

var _count := 0
var _failures := 0


func _check(label: String, ok: bool, detail := "") -> void:
	_count += 1
	if not ok:
		_failures += 1
	print("%s %s %s" % ["ok  " if ok else "FAIL", label, detail])


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var loaded: Dictionary = FieldLoader.load_from(FIELD)
	var field: Dictionary = loaded.field
	var built: Dictionary = CollisionSetup.build(field)
	_check("the Triglav field and its surveyed obstacles load", loaded.ok and built.ok and built.world.proxies.size() > 1000)
	var s: Node = Session.new()
	root.add_child(s)
	s.set_collision_world(built.world)
	var prepared: bool = s.prepare(field, {race_track = TRACK, throttle_limit = RaceTest.THROTTLE_LIMIT})
	_check("the Rateče meadow course prepares on the surveyed terrain", prepared and s.race != null, str(s.load_error))
	if prepared:
		_clearance(s.course, built.world.proxies)
		_race(s)
	s.queue_free()
	await _activity()
	print("%d checks, %d failed" % [_count, _failures])
	quit(1 if _failures > 0 else 0)


func _clearance(course: Dictionary, proxies: Array) -> void:
	var worst := INF
	var worst_id := ""
	var line_worst := INF
	var line_id := ""
	var gates: Array = course.gates
	for proxy: Dictionary in proxies:
		var top: float = -float(proxy.bounds_down_min)
		for gate: Dictionary in gates:
			for frame: Dictionary in gate.frames:
				var d := _rect_point(proxy, float(frame.north), float(frame.east)) - float(frame.half_z)
				if d < worst:
					worst = d
					worst_id = "%s near %s" % [proxy.id, gate.id]
		var pad_d := _rect_point(proxy, float(course.pad.north), float(course.pad.east)) - 1.5
		if pad_d < worst:
			worst = pad_d
			worst_id = "%s near the pad" % proxy.id
		for i in gates.size():
			var a: Dictionary = gates[i]
			var b: Dictionary = gates[(i + 1) % gates.size()]
			var low_top: float = minf(-float(a.c[2]) + float(a.h), -float(b.c[2]) + float(b.h))
			if top < low_top - 30.0:
				continue # far below the line (a gate top is at most ~16 m above the meadow)
			var d := _rect_segment(proxy, a.c[0], a.c[1], b.c[0], b.c[1])
			if d < line_worst:
				line_worst = d
				line_id = "%s on %s -> %s" % [proxy.id, a.id, b.id]
	print("    nearest obstacle to a gate frame or the pad %.1f m (%s); to a racing line %.1f m (%s)" % [worst, worst_id,
		line_worst, line_id])
	_check("every gate frame and the pad stand at least %.0f m from the surveyed trees and buildings" % GATE_CLEARANCE_M,
		worst >= GATE_CLEARANCE_M, worst_id)
	_check("the straight lines between gates pass at least %.0f m from them" % LINE_CLEARANCE_M,
		line_worst >= LINE_CLEARANCE_M, line_id)


## Horizontal distance from (north, east) to the proxy's axis-aligned bounds (0 inside).
static func _rect_point(proxy: Dictionary, north: float, east: float) -> float:
	var dn := maxf(maxf(float(proxy.bounds_north_min) - north, north - float(proxy.bounds_north_max)), 0.0)
	var de := maxf(maxf(float(proxy.bounds_east_min) - east, east - float(proxy.bounds_east_max)), 0.0)
	return sqrt(dn * dn + de * de)


## Horizontal distance from segment a-b to the proxy's bounds, by dense sampling (0.25 m) along the segment.
static func _rect_segment(proxy: Dictionary, an: float, ae: float, bn: float, be: float) -> float:
	var length := sqrt((bn - an) * (bn - an) + (be - ae) * (be - ae))
	# Quick reject: the box is far from both ends and the segment's bounding box.
	if minf(an, bn) - 50.0 > float(proxy.bounds_north_max) or maxf(an, bn) + 50.0 < float(proxy.bounds_north_min) \
			or minf(ae, be) - 50.0 > float(proxy.bounds_east_max) or maxf(ae, be) + 50.0 < float(proxy.bounds_east_min):
		return INF
	var best := INF
	var steps := maxi(ceili(length / 0.25), 1)
	for k in steps + 1:
		var t := float(k) / steps
		best = minf(best, _rect_point(proxy, an + t * (bn - an), ae + t * (be - ae)))
	return best


func _race(s: Node) -> void:
	var events: Array = []
	s.race_event.connect(func(event: Dictionary) -> void: events.append(event))
	var ok: bool = s.reset_to_pad() and s.resume()
	ok = ok and s.tick_once(Fixtures.pilot(0.0, 0.0, 0.0, 0.0, 0, 1), Director.ACTION_START)
	for i in range(1, 720):
		ok = ok and s.tick_once(Fixtures.pilot(0.0, 0.0, 0.0, 0.0, 0 if i < 3 else 1, 1))
	ok = ok and s.tick_once(Fixtures.pilot(0.0, 0.0, 0.0, 0.0, 1, 1))
	var types: Array = events.map(func(e: Dictionary) -> String: return str(e.type))
	_check("a race starts from the pad on the meadow: countdown, then GO", ok and types == ["race_countdown", "race_go"]
		and str(s.telemetry().race.phase) == "RACING", str(types))
	var pilot: RefCounted = RaceTest.Pilot.new()
	pilot.cruise_mps = RaceTest.CRUISE_MPS
	var route: Array[PackedFloat64Array] = RaceTest.race_route(s.course, 3)
	pilot.fly(route, PackedFloat64Array([float(s.course.pad.north), float(s.course.pad.east)]))
	var gate_count: int = s.course.gate_count
	var top_agl := 0.0
	var flying := true
	for _i in 240 * 400:
		# Each leg climbs or descends to the height of the gate it leads to (two route points per gate).
		var gate: Dictionary = s.course.gates[mini(pilot.index, route.size() - 1) / 2 % gate_count]
		var ground: float = s.environment.ground(gate.c[0], gate.c[1])[0]
		pilot.height_m = -float(gate.c[2]) - ground
		flying = flying and s.tick_once(pilot.command(s))
		top_agl = maxf(top_agl, -s.sim.state[RB.POS + 2] - s.environment.ground(s.sim.state[RB.POS], s.sim.state[RB.POS + 1])[0])
		if not flying or not s.crash.is_empty() or str(s.telemetry().race.phase) != "RACING":
			break
	var race: Dictionary = s.telemetry().race
	var gates_passed := events.filter(func(e: Dictionary) -> bool: return str(e.type) == "race_gate").size()
	var laps: Array = events.filter(func(e: Dictionary) -> bool: return str(e.type) == "race_lap")
	print("    lap times %s s; highest %.1f m above the ground" % [str(laps.map(func(e: Dictionary) -> String:
		return "%.2f" % float(e.duration_s))), top_agl])
	_check("the scripted pilot flies three valid laps of all %d gates with no crash" % gate_count,
		flying and s.crash.is_empty() and str(race.phase) == "FINISHED" and int(race.valid_laps) == 3
		and gates_passed == 3 * gate_count, "phase %s laps %s gates %d crash %s" % [race.phase, race.valid_laps,
		gates_passed, str(s.crash)])


func _activity() -> void:
	var scene: Node = Scene.new()
	scene.field_path = FIELD
	_check("the FPV quad activity offers the Rateče meadow course on Triglav",
		scene._load_field() and scene._race_option == TRACK, scene._race_option)
	scene.race_track = ""
	_check("an explicit free flight stays free flight on Triglav", scene._load_field() and scene._race_option.is_empty())
	scene.field_path = FieldLoader.DEFAULT_PATH
	scene.race_track = Scene.RACE_TRACK
	_check("Club field keeps the practice oval", scene._load_field() and scene._race_option == Scene.RACE_TRACK)
	scene.free()
