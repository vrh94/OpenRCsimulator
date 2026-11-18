## Step 19 driver aids for the RC trucks. They act on the driver's commands before the session ticks, from the
## read-only state, the way a radio's throttle end point and a receiver gyro do; the truck physics is unchanged, and
## a recording keeps the commands the truck actually received.
##
## - Throttle limit: the throttle command is multiplied by it (a transmitter end point, or a training mode).
## - Stability assist, in the spirit of Traxxas Stability Management: when the truck yaws faster than the steering
##   asks for (a spin starting), it steers against the excess and eases the throttle; when the driven wheels spin
##   well above the ground speed, it eases the throttle. It also does what TSM does not: it limits how hard the
##   steering may turn at speed (a lateral-acceleration ceiling below the roll-over limit of a tall monster truck),
##   steers out of a building body roll and eases the throttle in a tall wheelie. 0 is off, 1 is the full
##   correction below.
extends RefCounted

const M := preload("res://physics/math3d.gd")

## Yaw-rate excess (rad/s) the assist ignores, so normal cornering and small wobbles stay untouched.
const YAW_DEADBAND := 0.25
## Wheel-spin ratio ((wheel surface speed - ground speed) / ground speed) the assist allows before easing throttle.
const SPIN_ALLOWED := 0.25
## The yaw rate the tires can hold at a given speed: about this many g of lateral acceleration.
const GRIP_G := 1.0
## Steering ceiling at full assist: the lateral acceleration (in g) the kinematic turn may ask for at speed.
const LATERAL_G := 0.7
## Body roll and wheelie angles (deg) above which the assist steers out of the roll or eases the throttle.
const ROLL_DEG := 10.0
const WHEELIE_DEG := 20.0
## Smoothing: the cut grows quickly and releases slowly, so the throttle does not chatter.
const ATTACK_S := 0.04
const RELEASE_S := 0.3

var throttle_limit := 1.0
var stability := 0.0

var _wheelbase := 0.48
var _max_steer := 0.5
var _tire_radius := 0.1
var _gravity := 9.81
var _cut := 0.0
var _counter := 0.0
## Last applied correction, for the HUD and tests: {cut, counter}.
var last := {"cut": 0.0, "counter": 0.0}


## Reads the geometry the assist needs from the session's model (the tuned one: steering lock follows the tune).
func configure(model: Dictionary) -> void:
	var x: Variant = model.get("corner_x_m")
	if x is PackedFloat64Array and x.size() == 4:
		_wheelbase = maxf(float(x[0]) - float(x[2]), 0.05)
	_max_steer = maxf(float(model.get("max_steer_angle_rad", _max_steer)), 0.05)
	_tire_radius = maxf(float(model.get("tire_radius_m", _tire_radius)), 0.01)
	_gravity = maxf(float(model.get("gravity_m_per_s2", _gravity)), 0.1)
	reset()


func reset() -> void:
	_cut = 0.0
	_counter = 0.0
	last = {"cut": 0.0, "counter": 0.0}


func active() -> bool:
	return throttle_limit < 1.0 or stability > 0.0


## Returns new controls; `controls` is not modified. `state` is the session's 31-value state before this tick.
func apply(controls: Dictionary, state: PackedFloat64Array, dt: float) -> Dictionary:
	var out := controls.duplicate()
	out.throttle = clampf(float(controls.get("throttle", 0.0)), 0.0, 1.0) * clampf(throttle_limit, 0.0, 1.0)
	if stability <= 0.0 or state.size() < 25:
		return out
	var cut_target := 0.0
	var counter_target := 0.0
	var u := state[3]
	var r := state[12]
	var steer_cmd := clampf(float(controls.get("steering", 0.0)), -1.0, 1.0)
	var steer_out := steer_cmd
	var reverse := bool(controls.get("reverse", false))
	var euler := M.q_to_euler(M.quat(state[6], state[7], state[8], state[9]))
	if u > 1.0 and not reverse:
		# Ceiling: the steering that asks for LATERAL_G at this speed, blended in by the assist level.
		var ceiling := atan(LATERAL_G * _gravity * _wheelbase / (u * u)) / _max_steer
		if ceiling < 1.0:
			steer_out = lerpf(steer_cmd, clampf(steer_cmd, -ceiling, ceiling), stability)
		var r_limit := GRIP_G * _gravity / u
		var r_ref := clampf(u * tan(steer_out * _max_steer) / _wheelbase, -r_limit, r_limit)
		# Yaw beyond what the steering asks for, or yaw against it.
		var excess := maxf(absf(r) - absf(r_ref), 0.0) if r * r_ref >= 0.0 else absf(r)
		excess = maxf(excess - YAW_DEADBAND, 0.0)
		if excess > 0.0:
			# Steering change that would remove the excess at this speed (kinematic yaw gain u / wheelbase).
			counter_target = clampf(-signf(r) * excess * _wheelbase / (u * _max_steer), -1.0, 1.0)
			cut_target = clampf(excess * 0.6, 0.0, 0.9)
		# Body roll: a right turn rolls the body left (negative roll); steering less into the turn unloads it.
		var roll_excess := absf(rad_to_deg(euler[2])) - ROLL_DEG
		if roll_excess > 0.0:
			counter_target = clampf(counter_target + signf(euler[2]) * roll_excess / 10.0, -1.0, 1.0)
			cut_target = maxf(cut_target, clampf(roll_excess / 15.0, 0.0, 0.9))
	if not reverse:
		var spin := 0.0
		for i in 4:
			spin += state[21 + i]
		spin = (spin * 0.25 * _tire_radius - u) / maxf(absf(u), 2.0)
		cut_target = maxf(cut_target, clampf((spin - SPIN_ALLOWED) * 1.5, 0.0, 0.8))
		cut_target = maxf(cut_target, clampf((rad_to_deg(euler[1]) - WHEELIE_DEG) / 20.0, 0.0, 0.9))
	var tau := ATTACK_S if cut_target > _cut else RELEASE_S
	_cut += (cut_target - _cut) * clampf(dt / tau, 0.0, 1.0)
	var tau_s := ATTACK_S if absf(counter_target) > absf(_counter) else RELEASE_S
	_counter += (counter_target - _counter) * clampf(dt / tau_s, 0.0, 1.0)
	out.throttle = float(out.throttle) * (1.0 - stability * _cut)
	out.steering = clampf(steer_out + stability * _counter, -1.0, 1.0)
	last = {"cut": stability * _cut, "counter": stability * _counter}
	return out
