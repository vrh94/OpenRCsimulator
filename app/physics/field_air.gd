extends RefCounted
## Triglav (owner decision 2026-11-21): a field built on surveyed terrain flies in the air at its real height. The
## field's elevation is the surveyed ground under its origin (physics/terrain_dem.gd ground_ref_m); flat fields keep
## the sea-level reference. The pilot's weather choice keeps its meaning at that height:
## - reference (the default literal sea-level air) becomes the standard atmosphere at the field: uniform, so every
##   vehicle class that admits uniform air flies in it, at ISA temperature and 1013.25 hPa, dry;
## - custom keeps the pilot's temperature, QNH and humidity and takes the field's elevation;
## - standard_column takes the field's elevation as its base.
## Applied where the launch hands weather to a session, so logs record the air the flight actually flew in.

const Atmosphere := preload("res://physics/atmosphere.gd")
const TerrainDem := preload("res://physics/terrain_dem.gd")
const WindConfig := preload("res://physics/wind_config.gd")


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
	return at_elevation(config, elevation_m(field))


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
