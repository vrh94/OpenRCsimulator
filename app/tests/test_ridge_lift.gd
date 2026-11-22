# Option 2 (2026-11-22): terrain-following spatial wind (openrc-spatial-wind v3, ridge lift) on surveyed fields.
# The schema and its refusals, the launch binding (bound on Triglav, plain v1 on flat fields), the updraft law against
# the smoothed terrain, and an airplane flying it on Triglav.
# Run: godot --headless --path . --audio-driver Dummy --script res://tests/test_ridge_lift.gd
extends SceneTree

const FieldLoader = preload("res://data/field_loader.gd")
const FieldAir = preload("res://physics/field_air.gd")
const WindConfig = preload("res://physics/wind_config.gd")
const SpatialConfig = preload("res://physics/wind_spatial_config.gd")
const SpatialField = preload("res://physics/wind_spatial_field.gd")
const Presets = preload("res://physics/wind_spatial_presets.gd")
const WindField = preload("res://physics/wind_field.gd")
const TerrainDem = preload("res://physics/terrain_dem.gd")
const Flight = preload("res://sim/flight_session.gd")
const M = preload("res://physics/math3d.gd")
const RB = preload("res://physics/rigid_body.gd")
const TRIGLAV := "res://landscapes/triglav_tamar/field.json"
const AIRCRAFT := "res://data/aircraft/jensen_ugly_stik_60.json"

var checks := 0
var failures := 0


func check(label: String, passed: bool, detail: String = "") -> void:
	checks += 1
	if passed:
		print("ok   ", label)
	else:
		failures += 1
		printerr("FAIL ", label, " ", detail)


func _initialize() -> void:
	var triglav: Dictionary = FieldLoader.load_from(TRIGLAV).field
	var club: Dictionary = FieldLoader.load_from().field
	var t: Dictionary = triglav.terrain
	var dem: RefCounted = TerrainDem.load_cached(t.core, t.ring, t.origin_east, t.origin_north)
	_schema()
	var weather := _ridge_weather(6.0, 90.0)
	check("the ridge preset validates as weather while unbound", WindConfig.validate(weather).ok,
		str(WindConfig.validate(weather).get("errors")))
	check("unbound terrain-following wind refuses to build", not WindField.build(weather).ok)

	var bound: Dictionary = FieldAir.weather(weather, triglav)
	check("a Triglav launch binds the field's surveyed terrain",
		typeof(bound.spatial_wind.terrain_flow.terrain) == TYPE_DICTIONARY
		and bound.spatial_wind.terrain_flow.terrain.identity == dem.identity)
	check("binding is idempotent", FieldAir.weather(bound, triglav) == bound)
	var built: Dictionary = WindField.build(bound)
	check("bound terrain-following wind builds", built.ok, str(built.get("errors")))
	var wrong: Dictionary = bound.duplicate(true)
	wrong.spatial_wind.terrain_flow.terrain.identity = "dem-000000000000000000000000"
	check("a terrain identity that does not match the grids is refused", not WindField.build(wrong).ok)

	var flat: Dictionary = FieldAir.weather(weather, club)
	check("on a flat field it flies as plain spatial wind", flat.spatial_wind.format == SpatialConfig.FORMAT
		and not flat.spatial_wind.has("terrain_flow") and WindField.build(flat).ok)
	var plain: Dictionary = weather.duplicate(true)
	plain.spatial_wind.format = SpatialConfig.FORMAT
	plain.spatial_wind.erase("terrain_flow")
	check("the flat-field wind is the ridge preset's own profile", WindField.build(flat).ok and flat == plain)
	if built.ok:
		_law(built.field, dem, bound)
	_smooth(dem)
	_flight(triglav, bound)
	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _ridge_weather(speed: float, from_deg: float) -> Dictionary:
	var weather: Dictionary = WindConfig.spatial_defaults()
	weather.spatial_wind = Presets.ridge_lift(speed, from_deg)
	return WindConfig.validate(weather).config


func _schema() -> void:
	var spatial: Dictionary = Presets.ridge_lift(6.0, 90.0)
	check("v3 resolves with an unbound terrain", SpatialConfig.resolve(spatial).ok)
	var bad_law: Dictionary = spatial.duplicate(true)
	bad_law.terrain_flow.law = "something-else"
	check("an unknown terrain-flow law is refused", not SpatialConfig.resolve(bad_law).ok)
	var bad_terrain: Dictionary = spatial.duplicate(true)
	bad_terrain.terrain_flow.terrain = "elsewhere"
	check("a terrain other than 'field' or a bound object is refused", not SpatialConfig.resolve(bad_terrain).ok)
	var outside: Dictionary = spatial.duplicate(true)
	outside.terrain_flow.terrain = {core = "user://core.json", ring = "res://r.json", origin_east_m = 0.0,
		origin_north_m = 0.0, identity = "dem-1"}
	check("terrain outside res:// is refused", not SpatialConfig.resolve(outside).ok)
	var extra: Dictionary = spatial.duplicate(true)
	extra.terrain_flow.extra = 1
	check("unknown terrain-flow fields are refused", not SpatialConfig.resolve(extra).ok)
	var no_flow: Dictionary = spatial.duplicate(true)
	no_flow.erase("terrain_flow")
	check("v3 requires terrain_flow", not SpatialConfig.resolve(no_flow).ok)
	var smoothing: Dictionary = spatial.duplicate(true)
	smoothing.terrain_flow.smoothing_m = 8.0
	check("smoothing below 32 m is refused", not SpatialConfig.resolve(smoothing).ok)


## The updraft is the profile wind along the smoothed slope, fading with height; lee slopes sink; inside the
## ground the air is still; the flat-site profile is measured above the surveyed ground.
func _law(field: RefCounted, dem: RefCounted, bound: Dictionary) -> void:
	var spatial: RefCounted = field.get("_spatial")
	var decay: float = float(bound.spatial_wind.terrain_flow.decay_height_m)
	var smoothing: float = float(bound.spatial_wind.terrain_flow.smoothing_m)
	var rng := RandomNumberGenerator.new()
	rng.seed = 22
	var worst := 0.0
	var windward := 0
	var lee := 0
	for i in 400:
		var north := rng.randf_range(-3000.0, 3000.0)
		var east := rng.randf_range(-3000.0, 3000.0)
		var height := rng.randf_range(5.0, 300.0)
		var ground: float = dem.sample(north, east)[0]
		var w: PackedFloat64Array = field.sample_world(PackedFloat64Array([north, east, -(ground + height)]), 30.0)
		var mean: PackedFloat64Array = spatial._profile_wind(height)
		var smooth: PackedFloat64Array = dem.smooth_sample(north, east, smoothing)
		var gn := smooth[1]
		var ge := smooth[2]
		var steep := sqrt(gn * gn + ge * ge)
		if steep > SpatialField.TERRAIN_FLOW_MAX_SLOPE:
			gn *= SpatialField.TERRAIN_FLOW_MAX_SLOPE / steep
			ge *= SpatialField.TERRAIN_FLOW_MAX_SLOPE / steep
		var expected := (mean[0] * gn + mean[1] * ge) * exp(-height / decay)
		worst = maxf(worst, absf(-w[2] - expected))
		worst = maxf(worst, absf(w[0] - mean[0]) + absf(w[1] - mean[1]))
		if expected > 0.5: windward += 1
		if expected < -0.5: lee += 1
	check("the updraft is the profile wind along the smoothed slope, fading with height", worst < 1e-9, str(worst))
	check("windward slopes lift and lee slopes sink", windward > 20 and lee > 20, "%d %d" % [windward, lee])
	var ground: float = dem.sample(-1000.0, -50.0)[0]
	var low: float = -field.sample_world(PackedFloat64Array([-1000.0, -50.0, -(ground + 30.0)]), 30.0)[2]
	var high: float = -field.sample_world(PackedFloat64Array([-1000.0, -50.0, -(ground + 600.0)]), 30.0)[2]
	print("east wind over the slope 1 km south of the pilot: %.2f m/s up at 30 m, %.2f m/s at 600 m" % [low, high])
	check("the preset's slope south of the pilot lifts, less with height", low > 1.0 and absf(high) < absf(low))
	var inside: PackedFloat64Array = field.sample_world(PackedFloat64Array([-1000.0, -50.0, -(ground - 3.0)]), 30.0)
	check("inside the ground the air is still", inside == PackedFloat64Array([0.0, 0.0, 0.0]))
	var summit_ground: float = dem.sample(-2000.0, -900.0)[0]
	var above_summit: PackedFloat64Array = field.sample_world(PackedFloat64Array([-2000.0, -900.0,
		-(summit_ground + 50.0)]), 30.0)
	check("heights are above the surveyed ground, so high terrain stays inside the domain",
		summit_ground > 200.0 and M.norm(above_summit) > 0.5 and _finite(above_summit), "%f" % summit_ground)


func _smooth(dem: RefCounted) -> void:
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 200:
		var north := rng.randf_range(-3000.0, 3000.0)
		var east := rng.randf_range(-3000.0, 3000.0)
		var at: PackedFloat64Array = dem.smooth_sample(north, east, 96.0)
		var dn: float = (dem.smooth_sample(north + 0.01, east, 96.0)[0] - dem.smooth_sample(north - 0.01, east, 96.0)[0]) / 0.02
		var de: float = (dem.smooth_sample(north, east + 0.01, 96.0)[0] - dem.smooth_sample(north, east - 0.01, 96.0)[0]) / 0.02
		worst = maxf(worst, maxf(absf(dn - at[1]), absf(de - at[2])))
	check("the smoothed terrain's slope is its derivative", worst < 1e-4, str(worst))


func _flight(field: Dictionary, weather: Dictionary) -> void:
	var s: Node = Flight.new()
	s.input_enabled = false
	s.crash_auto_restart = false
	s.setup(AIRCRAFT)
	root.add_child(s)
	var accepted: bool = s.set_field(field) and s.setup_weather(weather)
	check("the airplane accepts ridge lift on Triglav", accepted, str(s.get("weather_error")))
	if not accepted:
		s.queue_free()
		return
	s.start_choice = Flight.START_AIRBORNE
	s.reset()
	s.sim.set_paused(false)
	for tick: int in 240 * 8:
		s._physics_process(s.sim.dt())
		s.sim.step()
		if not s.crash.is_empty() or not s.sim.fault_reason.is_empty():
			break
	check("eight seconds of flight in ridge lift run without a fault", s.sim.fault_reason.is_empty() and s.sim.tick == 240 * 8,
		"%s tick %d %s" % [s.sim.fault_reason, s.sim.tick, s.crash])
	var metadata: Dictionary = s.trace_meta()
	check("the trace names the terrain-following wind", str(metadata.get("weather_model", "")) == "terrain-following-spatial-wind-v1",
			str(metadata.get("weather_model", "")))
	s.queue_free()


func _finite(v: PackedFloat64Array) -> bool:
	for x in v:
		if not is_finite(x): return false
	return true
