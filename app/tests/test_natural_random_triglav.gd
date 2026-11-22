# Option 6 (2026-11-22): Natural Random on the Triglav field. Triglav draws from its own v1 catalog (the Club wind
# recipes; Rateče's place, a June date, the field's 849.7 m and lapse-lowered temperatures); Club field keeps its
# synthetic sea-level catalog and every Club draw. A Triglav scenario is bound to the Triglav field, flies in the
# air it drew (the field-air binding leaves it unchanged) and starts airborne on the surveyed terrain.
# Run: godot --headless --path . --audio-driver Dummy --script res://tests/test_natural_random_triglav.gd
extends SceneTree

const ScenarioConfig := preload("res://scenarios/scenario_config.gd")
const NaturalRandomGen := preload("res://scenarios/natural_random.gd")
const FieldLoader := preload("res://data/field_loader.gd")
const FieldAir := preload("res://physics/field_air.gd")
const Catalog := preload("res://app_state/aircraft_catalog.gd")
const Flight := preload("res://sim/flight_session.gd")
const RB := preload("res://physics/rigid_body.gd")

const TRIGLAV := "res://landscapes/triglav_tamar/field.json"
const SEEDS := 40

var _checks := 0
var _failures := 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
	print("%s %s %s" % ["ok  " if ok else "FAIL", label, detail])


func _initialize() -> void:
	var triglav: Dictionary = FieldLoader.load_from(TRIGLAV).field
	var club_policy: Dictionary = ScenarioConfig.policy_catalog()
	var policy: Dictionary = ScenarioConfig.policy_catalog("triglav_tamar")
	_check("Club field keeps its synthetic sea-level catalog", float(club_policy.field_context.elevation_m) == 0.0
		and club_policy.field_context.location_name == "Reference field (synthetic)")
	_check("Triglav has its own catalog at the field's surveyed elevation", not policy.is_empty()
		and float(policy.field_context.elevation_m) == FieldAir.elevation_m(triglav), str(ScenarioConfig.policy_errors("triglav_tamar")))
	_check("with the Club wind recipes unchanged", not policy.is_empty() and policy.recipes == club_policy.recipes)
	_check("Natural Random is offered on Club field and Triglav only", ScenarioConfig.field_supported("default")
		and ScenarioConfig.field_supported("triglav_tamar") and not ScenarioConfig.field_supported("green"))
	if policy.is_empty():
		_finish()
		return
	var all_ok := true
	var bound := true
	var in_bands := true
	var same_draw := true
	var cross_refused := true
	var first: Dictionary = {}
	for seed in SEEDS:
		var drawn: Dictionary = NaturalRandomGen.generate(seed * 7919 + 3, TRIGLAV)
		var club: Dictionary = NaturalRandomGen.generate(seed * 7919 + 3)
		all_ok = all_ok and drawn.ok and club.ok
		if not drawn.ok or not club.ok:
			print("    ", drawn.errors, club.errors)
			continue
		var s: Dictionary = drawn.scenario
		if first.is_empty():
			first = s
		var w: Dictionary = s.weather_config
		bound = bound and s.field_id == "triglav_tamar" and float(w.field_elevation_m) == FieldAir.elevation_m(triglav) \
			and s.lighting_config.location_name == "Rateče, Slovenia" and s.lighting_config.date == "2026-06-20" \
			and ScenarioConfig.validate_sources(s, TRIGLAV).ok and FieldAir.weather(w, triglav) == w
		var daylight: Dictionary = {}
		for d: Dictionary in policy.daylight:
			if d.id == s.daylight_id:
				daylight = d
		in_bands = in_bands and float(w.temperature_c) >= float(daylight.temperature_c[0]) \
			and float(w.temperature_c) <= float(daylight.temperature_c[1])
		same_draw = same_draw and s.aircraft_id == club.scenario.aircraft_id and s.recipe_id == club.scenario.recipe_id \
			and s.daylight_id == club.scenario.daylight_id and w.speed_mps == club.scenario.weather_config.speed_mps
		cross_refused = cross_refused and not ScenarioConfig.validate_sources(s, FieldLoader.DEFAULT_PATH).ok \
			and not ScenarioConfig.validate_sources(club.scenario, TRIGLAV).ok
	_check("%d Triglav draws validate" % SEEDS, all_ok)
	_check("each is bound to Triglav: its field, elevation, place and date, and flies in the air it drew", bound)
	_check("temperatures stay in the Triglav daylight bands", in_bands)
	_check("the same seed draws the same aircraft, recipe, daylight and wind on both fields", same_draw)
	_check("a scenario is refused on the other field", cross_refused)
	var sea_level: Dictionary = first.duplicate(true)
	sea_level.weather_config.field_elevation_m = 0.0
	sea_level.identity = ScenarioConfig.identity_for(sea_level)
	_check("a Triglav scenario at sea level is refused", not ScenarioConfig.validate(sea_level).ok)
	var moved: Dictionary = first.duplicate(true)
	moved.lighting_config.latitude_deg = 0.0
	moved.identity = ScenarioConfig.identity_for(moved)
	_check("a Triglav scenario lit elsewhere is refused", not ScenarioConfig.validate(moved).ok)
	_fly(first, triglav)
	_finish()


func _fly(scenario: Dictionary, field: Dictionary) -> void:
	var s: Node = Flight.new()
	s.input_enabled = false
	s.crash_auto_restart = false
	var entry: Dictionary = Catalog.entry(str(scenario.aircraft_id))
	s.setup(Catalog.data_for(str(scenario.aircraft_id), Catalog.default_battery_mode(str(scenario.aircraft_id))),
		str(scenario.aircraft_id))
	root.add_child(s)
	var ok: bool = not entry.is_empty() and s.set_field(field) and s.setup_weather(FieldAir.weather(scenario.weather_config, field))
	s.start_choice = Flight.START_AIRBORNE
	s.reset()
	s.sim.set_paused(false)
	var start_agl: float = -s.sim.state[RB.POS + 2] - s.environment.terrain(s.sim.state[RB.POS], s.sim.state[RB.POS + 1])[0]
	for tick in 240 * 5:
		s._physics_process(s.sim.dt())
		s.sim.step()
		if not s.sim.fault_reason.is_empty():
			break
	_check("the drawn %s starts airborne over Triglav in the drawn air and flies 5 s" % scenario.aircraft_id,
		ok and not s.atmosphere_is_reference() and start_agl > 5.0 and s.sim.fault_reason.is_empty() and s.sim.tick == 240 * 5,
		"AGL %.1f m %s %s" % [start_agl, s.weather_error, s.sim.fault_reason])
	s.queue_free()


func _finish() -> void:
	print("%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
