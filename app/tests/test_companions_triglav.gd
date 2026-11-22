# Option 6 (2026-11-22): flight companions on the Triglav field. The Triglav field profile loads for the surveyed
# field and nowhere else; the manager admits it only on the Triglav landscape in the field's standard air (849.7 m)
# within the calm/gentle limits; the circuit controller flies Triglav only with its profile's bands; the launch
# clearance check bounds the ground under the circuit locally (not at the 1.8 km summit); and three companions fly
# their bands over the meadow, clear of the surveyed trees, while the player waits on the strip.
# Run: godot --headless --path . --audio-driver Dummy --script res://tests/test_companions_triglav.gd
extends SceneTree

const FlightSession := preload("res://sim/flight_session.gd")
const Catalog := preload("res://app_state/aircraft_catalog.gd")
const FieldLoader := preload("res://data/field_loader.gd")
const CollisionSetup := preload("res://scenery/collision_setup.gd")
const WindConfig := preload("res://physics/wind_config.gd")
const FieldAir := preload("res://physics/field_air.gd")
const Config := preload("res://ai/companions/config.gd")
const Manager := preload("res://ai/companions/manager.gd")
const Profiles := preload("res://ai/companions/profile_loader.gd")
const Circuit := preload("res://ai/companions/circuit_controller.gd")
const Airspace := preload("res://ai/companions/airspace.gd")
const RB := preload("res://physics/rigid_body.gd")

const TRIGLAV := "res://landscapes/triglav_tamar/field.json"
const FLIGHT_TICKS := 240 * 30

var _checks := 0
var _failures := 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%s %s %s" % ["ok  " if ok else "FAIL", label, detail])


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var triglav: Dictionary = FieldLoader.load_from(TRIGLAV).field
	var club: Dictionary = FieldLoader.load_from().field
	_profiles(triglav, club)
	_controller(triglav)
	var world: Dictionary = CollisionSetup.build(triglav).world
	_check("the Triglav collision world carries the surveyed trees and buildings", world.proxies.size() > 1000)
	var player: FlightSession = _player(triglav, world, FieldAir.weather(WindConfig.preset("calm"), triglav))
	_check("the player waits on the Triglav strip in the field's air", not player.atmosphere_is_reference())
	_admission(player, triglav, club)
	_fly(player, triglav, world)
	player.queue_free()
	print("%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _source_identity() -> Dictionary:
	var path: String = str(Catalog.entry(Config.AIRCRAFT_ID).data)
	return {format = "openrc-aircraft v2", sha256 = FileAccess.get_sha256(path)}


func _profiles(triglav: Dictionary, club: Dictionary) -> void:
	var loaded: Dictionary = Profiles.load_profile(Config.AIRCRAFT_ID, _source_identity(), triglav)
	_check("the Stik loads its Triglav field profile", loaded.get("ok", false), str(loaded.get("errors", [])))
	if loaded.get("ok", false):
		var circuit: Dictionary = loaded.field_profile.circuit
		_check("the Triglav circuit is the strip-derived 80 m circle 160 m north, 45 m and 20 m bands",
			float(circuit.center_north.value) == 160.0 and float(circuit.radius.value) == 80.0
			and float(circuit.base_agl.value) == 45.0 and float(circuit.slot_agl_step.value) == 20.0)
		_check("the launch identity names the Triglav profile and field",
			loaded.identity.field_profile_id == "triglav-tamar" and loaded.identity.field_data_path == TRIGLAV)
	var club_loaded: Dictionary = Profiles.load_profile(Config.AIRCRAFT_ID, _source_identity(), club)
	_check("Club field keeps its own profile", club_loaded.get("ok", false)
		and club_loaded.identity.field_profile_id == "club-default"
		and float(club_loaded.field_profile.circuit.base_agl.value) == 35.0, str(club_loaded.get("errors", [])))
	var aircraft: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Profiles.AIRCRAFT_PROFILE_PATHS[Config.AIRCRAFT_ID]))
	var field_profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Profiles.FIELD_PROFILE_PATHS["triglav-tamar"]))
	var swapped: Dictionary = Profiles.validate_profile_data(aircraft, field_profile, Config.AIRCRAFT_ID, _source_identity(), club)
	_check("the Triglav profile refuses Club field geometry", not swapped.get("ok", false))
	var unlisted: Dictionary = aircraft.duplicate(true)
	unlisted.field_profile_ids = ["club-default"]
	_check("an aircraft profile that does not list Triglav is refused there",
		not Profiles.validate_profile_data(unlisted, field_profile, Config.AIRCRAFT_ID, _source_identity(), triglav).get("ok", false))
	var low: Dictionary = field_profile.duplicate(true)
	low.circuit.base_agl.value = 35.0
	_check("Club-field bands are refused on Triglav",
		not Profiles.validate_profile_data(aircraft, low, Config.AIRCRAFT_ID, _source_identity(), triglav).get("ok", false))
	var high: Dictionary = field_profile.duplicate(true)
	high.qualification.observed.max_agl.value = 92.6
	_check("observations above the top band are refused",
		not Profiles.validate_profile_data(aircraft, high, Config.AIRCRAFT_ID, _source_identity(), triglav).get("ok", false))
	_check("Home and pause offer companions at Club field and Triglav only",
		Profiles.landscape_qualified("club_field") and Profiles.landscape_qualified("triglav_tamar")
		and not Profiles.landscape_qualified("lake") and not Profiles.landscape_qualified(""))


func _controller(triglav: Dictionary) -> void:
	var trim := {V = 15.5, throttle = 0.5}
	var plain := Circuit.new()
	_check("the circuit controller refuses Triglav without its profile's bands",
		not plain.configure(0, 1, 1, trim, triglav))
	var field_profile: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Profiles.FIELD_PROFILE_PATHS["triglav-tamar"]))
	var pilot := Circuit.new()
	var ok := pilot.configure(2, 3, 1, trim, triglav, field_profile.circuit)
	_check("with them the top slot flies 85 m above the pilot", ok and pilot.initial_pose().height_agl_m == 85.0,
		pilot.configure_error)
	var moved: Dictionary = field_profile.circuit.duplicate(true)
	moved.center_north.value = 170.0
	_check("a circuit that is not the strip-derived route is refused", not Circuit.new().configure(0, 1, 1, trim, triglav, moved))


func _player(field: Dictionary, world: Dictionary, weather: Dictionary) -> FlightSession:
	var player: FlightSession = FlightSession.new()
	player.input_enabled = false
	player.setup(Catalog.entry(Catalog.DEFAULT_ID).data, Catalog.DEFAULT_ID)
	var ok: bool = player.set_field(field) and player.setup_weather(weather)
	player.start_choice = FlightSession.START_RUNWAY
	player.reset()
	ok = ok and player.set_collision_world(world)
	_check("a player session installs on Triglav", ok, player.surface_error + player.weather_error)
	root.add_child(player)
	player.set_physics_process(false)
	player.sim.set_physics_process(false)
	return player


func _requested(count: int) -> Dictionary:
	var requested: Dictionary = Config.defaults()
	requested.enabled = true
	requested.count = count
	requested.seed = 20261122
	return requested


func _admission(player: FlightSession, triglav: Dictionary, club: Dictionary) -> void:
	var admitted: Dictionary = Manager.validate_context(player, triglav, "triglav_tamar", _requested(3))
	_check("three companions are admitted on Triglav in the field's standard air", admitted.get("ok", false),
		str(admitted.get("errors", [])))
	_check("the Triglav field is refused under another landscape",
		not Manager.validate_context(player, triglav, "club_field", _requested(1)).get("ok", false))
	var reference: FlightSession = _player(triglav, {}, WindConfig.preset("calm"))
	var at_sea_level: Dictionary = Manager.validate_context(reference, triglav, "triglav_tamar", _requested(1))
	_check("sea-level reference air is refused on Triglav (the profile was flown at 849.7 m)",
		reference.atmosphere_is_reference() and not at_sea_level.get("ok", false), str(at_sea_level))
	reference.queue_free()
	var warm: Dictionary = FieldAir.weather(WindConfig.preset("calm"), triglav)
	warm.temperature_c = 25.0
	var hot: FlightSession = _player(triglav, {}, warm)
	_check("other air on Triglav is refused",
		not Manager.validate_context(hot, triglav, "triglav_tamar", _requested(1)).get("ok", false))
	hot.queue_free()
	var windy: FlightSession = _player(triglav, {}, FieldAir.weather(WindConfig.preset("turbulent"), triglav))
	_check("turbulence above the gentle-breeze limit is refused on Triglav",
		not Manager.validate_context(windy, triglav, "triglav_tamar", _requested(1)).get("ok", false))
	windy.queue_free()


func _fly(player: FlightSession, field: Dictionary, world: Dictionary) -> void:
	var manager: Node = Manager.new()
	var configured: Dictionary = manager.configure(player, field, "triglav_tamar", _requested(3), false, false)
	_check("three companions launch over the Rateče meadow", configured.get("ok", false) and manager.agents.size() == 3,
		str(configured))
	if not configured.get("ok", false):
		manager.free()
		return
	var report: Dictionary = manager.status().airspace_report
	_check("the launch clearance bounds the ground under the circuit locally, not at the summit",
		float(report.get("ground_upper_m", INF)) < 20.0 and int(report.get("proxy_count", 0)) == world.proxies.size(),
		"ground bound %.2f m" % float(report.get("ground_upper_m", NAN)))
	root.add_child(manager)
	var min_agl := INF
	var max_agl := -INF
	var flying := true
	var why := ""
	for tick in FLIGHT_TICKS:
		player.commands = {roll = 0.0, pitch = 0.0, yaw = 0.0, throttle = 0.0}
		player.raw = player.commands.duplicate()
		player.sim.inputs = player._inputs()
		if not player._session_after_input():
			flying = false
			why = "player refused tick %d: %s %s" % [tick, player.sim.fault_reason, str(player.crash)]
			break
		player.sim.step()
		for agent: Node in manager.agents:
			var s: PackedFloat64Array = agent.session.sim.state
			var agl: float = -s[RB.POS + 2] - agent.session.environment.terrain(s[RB.POS], s[RB.POS + 1])[0]
			min_agl = minf(min_agl, agl)
			max_agl = maxf(max_agl, agl)
			var agent_ok: bool = agent.session.crash.is_empty() and agent.session.sim.fault_reason.is_empty() \
				and agent.session.sim.tick == tick + 1
			if not agent_ok and why.is_empty():
				why = "%s at tick %d: tick %d crash %s fault %s; manager %s" % [agent.name, tick, agent.session.sim.tick,
					str(agent.session.crash), agent.session.sim.fault_reason, manager.error]
			flying = flying and agent_ok
		if not flying:
			break
	_check("they fly 30 s over the meadow with no crash, fault or skipped tick", flying and manager.accepted_ticks == FLIGHT_TICKS,
		"accepted %d %s" % [manager.accepted_ticks, why])
	_check("each stays above the controller's 30 m recovery band and below its top band",
		min_agl > 30.0 and max_agl < 95.0, "AGL %.1f..%.1f m" % [min_agl, max_agl])
	manager.queue_free()
