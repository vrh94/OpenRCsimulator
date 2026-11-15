## FC-2: the radio (RC) link between the pilot's transmitter at the pilot station and the receiver in the airplane.
## Off (the default) is a perfect link, as before. The other modes model a long-range control link with the same
## documented margin law as the video link (render/camera/video_link.gd), deliberately simple, not measured:
##   margin = 20·log10(R_half / d) − blockage
## R_half is where the link quality is 50 %; terrain between the antennas costs OBSTRUCTION_DB (lower frequencies
## bend round hills better), buildings and trees SCENERY_DB times their share of the path. The ranges are
## presentation choices in the range pilots report for stock antennas at ~100 mW (2.4 GHz: several km; 868/915 MHz:
## tens of km). When the quality stays below LOST_QUALITY for FAILSAFE_DELAY_S the receiver is in failsafe; it
## recovers after RECOVER_S above RECOVER_QUALITY. The link never moves a surface: the flight controller decides
## what a failsafe does (sim/fixed_wing_fc.gd).
extends RefCounted

const MODES: Array[String] = ["off", "elrs_2g4", "lr_900"]
const DEFAULT_MODE := "off"
const HALF_RANGE_M := {elrs_2g4 = 6000.0, lr_900 = 30000.0}
const OBSTRUCTION_DB := {elrs_2g4 = 22.0, lr_900 = 12.0}
const SCENERY_DB := {elrs_2g4 = 10.0, lr_900 = 5.0}
const MARGIN_SPAN_DB := 6.0
const NEAR_M := 5.0
const LOST_QUALITY := 0.15
const RECOVER_QUALITY := 0.5
const FAILSAFE_DELAY_S := 1.0
const RECOVER_S := 1.0
## The shown link quality follows a fade quickly and recovers a little slower, like a receiver's LQ.
const FADE_HALF_LIFE_S := 0.1
const RECOVER_HALF_LIFE_S := 0.3

var mode := DEFAULT_MODE
## 0 (no packets) … 1 (every packet), smoothed.
var quality := 1.0
## The receiver is in failsafe (no valid packets for FAILSAFE_DELAY_S).
var lost := false
var last := {}
var _below_s := 0.0
var _above_s := 0.0
var _primed := false


func configure(link_mode: String) -> void:
	if link_mode in MODES and link_mode != mode:
		mode = link_mode
		reset()


func enabled() -> bool:
	return mode != "off"


static func margin_db(link_mode: String, distance_m: float, terrain_blocked: bool, scenery_blocked: float) -> float:
	var d := maxf(distance_m, NEAR_M)
	var m := 20.0 * log(float(HALF_RANGE_M.get(link_mode, 1.0e9)) / d) / log(10.0)
	if terrain_blocked:
		m -= float(OBSTRUCTION_DB.get(link_mode, 0.0))
	return m - float(SCENERY_DB.get(link_mode, 0.0)) * clampf(scenery_blocked, 0.0, 1.0)


static func quality_of(margin: float) -> float:
	return smoothstep(-MARGIN_SPAN_DB, MARGIN_SPAN_DB, margin)


## One update (any rate). Returns the smoothed quality; `lost` follows with the failsafe delay.
func update(distance_m: float, terrain_blocked: bool, scenery_blocked: float, dt: float) -> float:
	if mode == "off":
		quality = 1.0
		lost = false
		return quality
	var m := margin_db(mode, distance_m, terrain_blocked, scenery_blocked)
	var target := quality_of(m) if distance_m > NEAR_M else 1.0
	if not _primed:
		quality = target
		_primed = true
	elif dt > 0.0:
		var half := FADE_HALF_LIFE_S if target < quality else RECOVER_HALF_LIFE_S
		quality = lerpf(quality, target, 1.0 - pow(2.0, -dt / half))
	if quality < LOST_QUALITY:
		_below_s += dt
		_above_s = 0.0
	elif quality > RECOVER_QUALITY:
		_above_s += dt
		_below_s = 0.0
	if not lost and _below_s >= FAILSAFE_DELAY_S:
		lost = true
	elif lost and _above_s >= RECOVER_S:
		lost = false
	last = {distance_m = distance_m, margin_db = m, terrain_blocked = terrain_blocked, quality = quality, lost = lost}
	return quality


## The OSD's link figure (%), or {} when no RC link is modelled.
func osd_link() -> Dictionary:
	return {} if mode == "off" else {quality_pct = 100.0 * quality}


func reset() -> void:
	quality = 1.0
	lost = false
	last = {}
	_below_s = 0.0
	_above_s = 0.0
	_primed = false
