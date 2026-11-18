## Step 19: a truck's tuning, saved per vehicle in user://ground_tuning.json and applied when the truck loads.
## The physical settings become the session's experiment knobs (physics/ground_vehicle/vehicle_data.gd
## with_experiment), so checkpoints and recordings carry them; the driver aids (vehicles/ground/driver_aids.gd)
## act on the commands. Stock values change nothing.
extends RefCounted

const VehicleData = preload("res://physics/ground_vehicle/vehicle_data.gd")

const PATH := "user://ground_tuning.json"
const FORMAT := "openrc-ground-tuning v1"
## Every setting, its stock value and range. Ranges follow VehicleData's experiment checks.
const SETTINGS := {
	"gear_scale": {"stock": 1.0, "min": 0.7, "max": 1.3},
	"steer_scale": {"stock": 1.0, "min": 0.5, "max": 1.3},
	"brake_scale": {"stock": 1.0, "min": 0.25, "max": 2.0},
	"spring_scale": {"stock": 1.0, "min": 0.5, "max": 2.0},
	"damper_scale": {"stock": 1.0, "min": 0.25, "max": 2.0},
	"grip_scale": {"stock": 1.0, "min": 0.15, "max": 2.0},
	"throttle_limit": {"stock": 1.0, "min": 0.25, "max": 1.0},
	"stability": {"stock": 0.0, "min": 0.0, "max": 1.0},
}
const DRIVER_AIDS := ["throttle_limit", "stability"]
## Lab-only experiment knobs and their neutral values; the tune never changes them.
const LAB_NEUTRAL := {"gravity_scale": 1.0, "ballast_kg": 0.0, "ballast_height_m": 0.15}


static func stock() -> Dictionary:
	var values := {}
	for key: String in SETTINGS:
		values[key] = float(SETTINGS[key].stock)
	return values


## Unknown keys are dropped, missing ones take the stock value and every value is clamped to its range.
static func sanitize(raw: Variant) -> Dictionary:
	var values := stock()
	if raw is Dictionary:
		for key: String in SETTINGS:
			var value: Variant = raw.get(key)
			if (value is float or value is int) and is_finite(float(value)):
				values[key] = clampf(float(value), float(SETTINGS[key].min), float(SETTINGS[key].max))
	return values


static func is_stock(values: Dictionary) -> bool:
	return physical_is_stock(values) and aids_are_stock(values)


static func physical_is_stock(values: Dictionary) -> bool:
	for key: String in SETTINGS:
		if not key in DRIVER_AIDS and not is_equal_approx(float(values.get(key, SETTINGS[key].stock)), float(SETTINGS[key].stock)):
			return false
	return true


static func aids_are_stock(values: Dictionary) -> bool:
	for key: String in DRIVER_AIDS:
		if not is_equal_approx(float(values.get(key, SETTINGS[key].stock)), float(SETTINGS[key].stock)):
			return false
	return true


## The session experiment for a tune, with the Physics lab's gravity and ballast (neutral unless given).
## Gearing, steering and brakes are included only when changed, so a stock tune keeps the old identity.
static func experiment(values: Dictionary, lab: Dictionary = {}) -> Dictionary:
	var knobs := {}
	for key: String in LAB_NEUTRAL:
		knobs[key] = float(lab.get(key, LAB_NEUTRAL[key]))
	for key: String in ["grip_scale", "spring_scale", "damper_scale"]:
		knobs[key] = float(values.get(key, 1.0))
	for key: String in VehicleData.TUNING_KEYS:
		var value := float(values.get(key, 1.0))
		if not is_equal_approx(value, 1.0):
			knobs[key] = value
	return knobs


static func load_all(path := PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or parsed.get("format") != FORMAT or not parsed.get("vehicles") is Dictionary:
		return {}
	return parsed.vehicles


static func load_for(vehicle_id: String, path := PATH) -> Dictionary:
	return sanitize(load_all(path).get(vehicle_id))


## Writes atomically (temporary file, then rename); other trucks' tunes are kept.
static func save_for(vehicle_id: String, values: Dictionary, path := PATH) -> bool:
	var all := load_all(path)
	var clean := sanitize(values)
	if is_stock(clean):
		all.erase(vehicle_id)
	else:
		all[vehicle_id] = clean
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"format": FORMAT, "vehicles": all}, "\t", true) + "\n")
	file.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path)) == OK


## No-load ground speed (km/h) of an electric model, for the garage's gearing readout; 0 for nitro.
static func free_speed_kmh(model: Dictionary) -> float:
	if model.get("powertrain") is Dictionary:
		return 0.0
	return float(model.get("drive_torque_fade_rad_s", 0.0)) * float(model.get("tire_radius_m", 0.0)) * 3.6
