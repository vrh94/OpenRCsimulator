extends RefCounted
## Triglav (owner decision 2026-11-21): a field built on surveyed terrain flies in the air at its real height. The
## field's elevation is the surveyed ground under its origin (physics/terrain_dem.gd ground_ref_m); flat fields keep
## the sea-level reference. The pilot's weather choice keeps its meaning at that height:
## - reference (the default literal sea-level air) becomes the standard atmosphere at the field: uniform, so every
##   vehicle class that admits uniform air flies in it, at ISA temperature and 1013.25 hPa, dry;
## - custom keeps the pilot's temperature, QNH and humidity and takes the field's elevation;
## - standard_column takes the field's elevation as its base.
## Applied where the launch hands weather to a session, so logs record the air the flight actually flew in.
## Option 2 (2026-11-22): the same step binds terrain-following spatial wind (v3, ridge lift) to the field's surveyed
## terrain; on a flat field it flies as the plain spatial wind (v1) it extends.

const Atmosphere := preload("res://physics/atmosphere.gd")
const TerrainDem := preload("res://physics/terrain_dem.gd")
const WindConfig := preload("res://physics/wind_config.gd")
const SpatialConfig := preload("res://physics/wind_spatial_config.gd")


## Metres above sea level of the field origin; 0.0 for a field without surveyed terrain.
static func elevation_m(field: Dictionary) -> float:
	var terrain: Variant = field.get("terrain", {})
	if typeof(terrain) != TYPE_DICTIONARY or (terrain as Dictionary).is_empty():
		return 0.0
	var dem: RefCounted = TerrainDem.load_cached(str(terrain.get("core", "")), str(terrain.get("ring", "")),
		float(terrain.get("origin_east", NAN)), float(terrain.get("origin_north", NAN)))
	return snappedf(dem.ground_ref_m, 0.1) if dem.ok() else 0.0


## The weather `config` as flown on `field`. Unchanged on flat fields and for configs that are not dictionaries
## (setup_weather reports those). Idempotent.
static func weather(config: Variant, field: Dictionary) -> Variant:
	return bind_terrain(at_elevation(config, elevation_m(field)), field)


## The weather `config` with terrain-following spatial wind bound to `field`'s surveyed terrain, or reduced to plain
## spatial wind on a field without one. Other configs are returned unchanged. Idempotent.
static func bind_terrain(config: Variant, field: Dictionary) -> Variant:
	if typeof(config) != TYPE_DICTIONARY or str(config.get("format", "")) != WindConfig.SPATIAL_FORMAT:
		return config
	var spatial: Variant = config.get("spatial_wind")
	if typeof(spatial) != TYPE_DICTIONARY or str(spatial.get("format", "")) != SpatialConfig.FORMAT_V3:
		return config
	var bound: Dictionary = (config as Dictionary).duplicate(true)
	var terrain: Variant = field.get("terrain", {})
	var dem: RefCounted = null
	if typeof(terrain) == TYPE_DICTIONARY and not (terrain as Dictionary).is_empty():
		dem = TerrainDem.load_cached(str(terrain.get("core", "")), str(terrain.get("ring", "")),
			float(terrain.get("origin_east", NAN)), float(terrain.get("origin_north", NAN)))
	if dem == null or not dem.ok():
		bound.spatial_wind.format = SpatialConfig.FORMAT
		bound.spatial_wind.erase("terrain_flow")
		return bound
	bound.spatial_wind.terrain_flow.terrain = {core = str(terrain.core), ring = str(terrain.ring),
		origin_east_m = float(terrain.origin_east), origin_north_m = float(terrain.origin_north), identity = dem.identity}
	return bound


## The weather `config` as flown on a field `elevation` metres above sea level (0.0: unchanged).
static func at_elevation(config: Variant, elevation: float) -> Variant:
	if elevation == 0.0 or typeof(config) != TYPE_DICTIONARY:
		return config
	var source: Dictionary = config
	var mode := str(source.get("atmosphere_mode", "reference"))
	if mode in ["custom", "standard_column"]:
		var moved: Dictionary = source.duplicate(true)
		moved.field_elevation_m = elevation
		return moved
	var air: Dictionary = Atmosphere.standard_column(elevation)
	return WindConfig.upgrade_atmosphere(source, {atmosphere_mode = "custom", field_elevation_m = elevation,
		temperature_c = snappedf(float(air.temperature_k) - 273.15, 0.01), qnh_hpa = 1013.25,
		relative_humidity_pct = 0.0})
