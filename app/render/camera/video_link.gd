# FPV-7: an analog 5.8 GHz video link between the aircraft's video transmitter and the pilot's receiver (at the pilot
# station), presentation only: it decides how broken the onboard picture looks and the OSD's signal figure. Nothing
# reaches the session and the aircraft flies the same with any link.
# The model is a link margin in dB, deliberately simple and documented rather than measured:
#   margin = 20·log10(R_half / d) − blockage + flutter
# where R_half (the distance at which the picture is half broken) grows with the square root of the transmitter
# power (free-space path loss: +6 dB per doubled distance), blockage is OBSTRUCTION_DB for terrain between the
# antennas and SCENERY_DB times the share of the path through buildings and trees, and flutter is a small
# deterministic fade (multipath) of the presentation clock. Quality is 1 above +MARGIN_SPAN_DB and 0 below
# −MARGIN_SPAN_DB (a smoothstep). R_half for 25 mW is a presentation choice in the range pilots report for stock
# antennas (a few hundred metres); higher powers scale it.
extends RefCounted

const MODES: Array[String] = ["off", "analog"]
const DEFAULT_MODE := "analog"
## FC-3 adds the long-range 1.6 W and 2.5 W transmitters.
const POWERS_MW: Array[int] = [25, 200, 600, 1000, 1600, 2500]
## FC-3: the receiving antenna at the pilot station: the stock omni, or a directional patch or helical kept pointed
## at the airplane (a tracker or the pilot). Gain in dB over the omni (+8 dB ≈ 2.5× range, +13 dB ≈ 4.5×).
const ANTENNAS: Array[String] = ["omni", "patch", "helical"]
const DEFAULT_ANTENNA := "omni"
const ANTENNA_GAIN_DB := {omni = 0.0, patch = 8.0, helical = 13.0}
const DEFAULT_POWER_MW := 600
const R_HALF_25MW_M := 600.0
const MARGIN_SPAN_DB := 6.0
const OBSTRUCTION_DB := 24.0
const SCENERY_DB := 12.0
const FLUTTER_DB := 1.5
const FLUTTER_HZ := 3.0
## The shown quality follows the instantaneous one quickly on a fade and recovers a little slower, like a receiver.
const FADE_HALF_LIFE_S := 0.05
const RECOVER_HALF_LIFE_S := 0.2
## Below this distance the antennas are always in each other's near field: never broken.
const NEAR_M := 5.0

var mode := DEFAULT_MODE
var power_mw := DEFAULT_POWER_MW
var antenna := DEFAULT_ANTENNA
## 0 (lost) … 1 (clean), smoothed.
var quality := 1.0
var _primed := false
var last := {}


func configure(link_mode: String, power: int, receiver_antenna := "") -> void:
	if link_mode in MODES:
		mode = link_mode
	if power in POWERS_MW:
		power_mw = power
	if receiver_antenna in ANTENNAS:
		antenna = receiver_antenna


func enabled() -> bool:
	return mode != "off"


## The distance (m) at which the picture is half broken for `power` mW.
static func half_range_m(power: float) -> float:
	return R_HALF_25MW_M * sqrt(maxf(power, 1.0) / 25.0)


## Link margin (dB). distance_m: transmitter to receiver; terrain_blocked: the straight path is under the ground;
## scenery_blocked: share (0…1) of the path through buildings and trees; clock_s: presentation clock (flutter).
## gain_db: the receiving antenna's gain over the stock omni (ANTENNA_GAIN_DB).
static func margin_db(distance_m: float, power: float, terrain_blocked: bool, scenery_blocked: float, clock_s: float,
		gain_db := 0.0) -> float:
	var d := maxf(distance_m, NEAR_M)
	var m := 20.0 * log(half_range_m(power) / d) / log(10.0) + gain_db
	if terrain_blocked:
		m -= OBSTRUCTION_DB
	m -= SCENERY_DB * clampf(scenery_blocked, 0.0, 1.0)
	if is_finite(clock_s):
		m += FLUTTER_DB * (sin(clock_s * TAU * FLUTTER_HZ) * 0.6 + sin(clock_s * TAU * FLUTTER_HZ * 2.37 + 1.3) * 0.4)
	return m


## Quality (0…1) for a margin.
static func quality_of(margin: float) -> float:
	return smoothstep(-MARGIN_SPAN_DB, MARGIN_SPAN_DB, margin)


## One frame: updates and returns the smoothed quality. dt: frame time (s).
func update(distance_m: float, terrain_blocked: bool, scenery_blocked: float, clock_s: float, dt: float) -> float:
	if mode == "off":
		quality = 1.0
		return quality
	var m := margin_db(distance_m, float(power_mw), terrain_blocked, scenery_blocked, clock_s, float(ANTENNA_GAIN_DB.get(antenna, 0.0)))
	var target := quality_of(m) if distance_m > NEAR_M else 1.0
	if not _primed:
		quality = target
		_primed = true
	elif dt > 0.0:
		var half := FADE_HALF_LIFE_S if target < quality else RECOVER_HALF_LIFE_S
		quality = lerpf(quality, target, 1.0 - pow(2.0, -dt / half))
	last = {distance_m = distance_m, margin_db = m, terrain_blocked = terrain_blocked, scenery_blocked = scenery_blocked,
		quality = quality}
	return quality


## How broken the picture is (0 clean … 1 lost), the shader's input.
func breakup() -> float:
	return 0.0 if mode == "off" else clampf(1.0 - quality, 0.0, 1.0)


## The OSD's signal figure (%), or {} when no link is modelled.
func osd_link() -> Dictionary:
	return {} if mode == "off" else {quality_pct = 100.0 * quality}


func reset() -> void:
	_primed = false
	quality = 1.0
	last = {}
