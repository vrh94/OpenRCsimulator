## Render boundary for the X-Maxx 8S replica (research/x-maxx/XM-02 builds the GLB from assets/vehicles/x-maxx/design.json).
## The GLB carries only meshes and named pivots; this script poses them from the read-only physics state.
## Shape and proportions only: no logos or graphics.
extends RefCounted

const Frames = preload("res://render/frames.gd")
const VehiclePaint = preload("res://render/vehicle_paint.gd")
const SCENE := "res://assets/vehicles/x-maxx/x_maxx.glb"
const VEHICLE_ID := "x-maxx-8s"
const CORNERS := ["FL", "FR", "RL", "RR"]
const PARTS := ["ArmLower", "ArmUpper", "Shock", "ShockRod", "Driveshaft", "Suspension", "Steer", "Hub", "Spin", "WheelMesh"]

# Rig constants: XM-02's (research/x-maxx/XM-02/build_model.py) and the XM-01 data's; test_x_maxx.gd checks they agree.
const WHEEL_X := 0.219
const REST_Y := -0.027
const Z_FRONT := -0.24
const ARM_IN := 0.05
const ARM_L := 0.169
const ARM_LOWER_Y := -0.035
const ARM_UPPER_Y := 0.020
const SHOCK_TOP := Vector2(0.085, 0.13)
const SHOCK_ARM := Vector2(0.13, 0.01)
const SHOCK_BODY_LEN := 0.10
const SHOCK_ROD_LEN := 0.10
const DIFF_OUT_X := 0.065
const DIFF_Y := -0.012
const HUB_INSET := 0.04
const TRAVEL_BUMP := 0.065
const TRAVEL_DROOP := 0.085
const STEER_MAX := PI / 6.0
# Lamp lens centres (right side; ground_effects mirrors them): XM-02's headlight and tail-light panels.
const HEAD_LAMP := Vector3(0.13, 0.087, -0.345)
const TAIL_LAMP := Vector3(0.15, 0.135, 0.342)


## `skin` is a stock paint id from data/vehicle_paints.json ("" or unknown = the red default).
static func build(skin := "") -> Dictionary:
	var packed := load(SCENE) as PackedScene
	if packed == null:
		return {"ok": false, "error": "X-Maxx visual resource is unavailable"}
	var imported := packed.instantiate() as Node3D
	var nodes := {}
	var error := _collect(imported, nodes)
	for required in ["XMaxx_Root", "Chassis", "Body", "Bumper_F", "Bumper_R"]:
		if error.is_empty() and not nodes.has(required):
			error = "Missing X-Maxx binding: " + required
	for corner: String in CORNERS:
		for part: String in PARTS:
			if error.is_empty() and not nodes.has(corner + "_" + part):
				error = "Missing X-Maxx binding: " + corner + "_" + part
	if not error.is_empty():
		imported.free()
		return {"ok": false, "error": error}
	var root := Node3D.new()
	root.name = "XMaxx8S"
	root.add_child(imported)
	var paint: Dictionary = VehiclePaint.apply(root, VEHICLE_ID, skin)
	var visual := {"ok": true, "error": "", "root": root, "nodes": nodes, "travel_outside_art": false,
		"skin": str(paint.get("skin", "")), "lamp_anchors": {head = HEAD_LAMP, tail = TAIL_LAMP}}
	_pose(visual, {"FL": 0.0, "FR": 0.0, "RL": 0.0, "RR": 0.0}, {"FL": 0.0, "FR": 0.0, "RL": 0.0, "RR": 0.0}, 0.0)
	return visual


static func _collect(node: Node, nodes: Dictionary) -> String:
	if node is CollisionObject3D or node is CollisionShape3D or node is AnimationPlayer:
		return "Art must not own simulation: " + str(node.name)
	if node is Node3D:
		if nodes.has(str(node.name)):
			return "Duplicate X-Maxx binding: " + str(node.name)
		nodes[str(node.name)] = node
	for child in node.get_children():
		var error := _collect(child, nodes)
		if not error.is_empty():
			return error
	return ""


## State is read-only. Compliant stops can exceed the drawn travel; only the drawing saturates, with a flag.
static func draw(visual: Dictionary, state: PackedFloat64Array, cg_height_m: float) -> bool:
	if state.size() < 31 or not visual.get("ok", false):
		return false
	for index in 31:
		if not is_finite(state[index]):
			return false
	var rotation := Frames.quat_to_render(state.slice(6, 10))
	var position := Frames.ned_to_render([state[0], state[1], state[2]])
	visual.root.transform = Frames.root_transform(rotation, position, Vector3(0, cg_height_m, 0))
	var travel := {}
	var spin := {}
	visual.travel_outside_art = false
	for i in 4:
		travel[CORNERS[i]] = clampf(state[13 + i], -TRAVEL_DROOP, TRAVEL_BUMP)
		spin[CORNERS[i]] = -fmod(state[25 + i], TAU)
		visual.travel_outside_art = visual.travel_outside_art or absf(travel[CORNERS[i]] - state[13 + i]) > 0.001
	_pose(visual, travel, spin, clampf(-state[29], -STEER_MAX, STEER_MAX))
	return true


static func side_of(corner: String) -> float:
	return -1.0 if corner[1] == "L" else 1.0


static func axle_z(corner: String) -> float:
	return Z_FRONT if corner[0] == "F" else -Z_FRONT


static func _pose(visual: Dictionary, travel: Dictionary, spin: Dictionary, steer: float) -> void:
	var n: Dictionary = visual.nodes
	for c: String in CORNERS:
		var s := side_of(c)
		var za := axle_z(c)
		var th := asin(clampf(float(travel[c]), -TRAVEL_DROOP, TRAVEL_BUMP) / ARM_L)
		var rot_arm := Basis(Vector3.BACK, s * th)
		n[c + "_ArmLower"].transform = Transform3D(rot_arm, Vector3(s * ARM_IN, ARM_LOWER_Y, za))
		n[c + "_ArmUpper"].transform = Transform3D(rot_arm, Vector3(s * ARM_IN, ARM_UPPER_Y, za))
		var off := Vector3(s * ARM_L * (cos(th) - 1.0), ARM_L * sin(th), 0.0)
		var wheel := Vector3(s * WHEEL_X, REST_Y, za) + off
		n[c + "_Suspension"].transform = Transform3D(Basis(), wheel)
		var d := steer if c[0] == "F" else 0.0
		n[c + "_Steer"].transform = Transform3D(Basis(Vector3.UP, d), Vector3.ZERO)
		n[c + "_Spin"].transform = Transform3D(Basis(Vector3.RIGHT, float(spin[c])), Vector3.ZERO)
		# Shock: top mount fixed on the tower, lower mount on the lower arm; the rod slides out of the body.
		var top := Vector3(s * SHOCK_TOP.x, SHOCK_TOP.y, za)
		var low := Vector3(s * ARM_IN, ARM_LOWER_Y, za) + rot_arm * Vector3(s * SHOCK_ARM.x, SHOCK_ARM.y, 0.0)
		var span := low - top
		var length := span.length()
		n[c + "_Shock"].transform = Transform3D(Basis(Quaternion(Vector3.DOWN, span / length)), top)
		n[c + "_ShockRod"].transform = Transform3D(Basis(), Vector3(0.0, -(length - SHOCK_ROD_LEN), 0.0))
		# Driveshaft: differential output to the hub's inner joint, a unit-length mesh scaled along local +X.
		var pin := Vector3(s * DIFF_OUT_X, DIFF_Y, za)
		var outer := wheel + Basis(Vector3.UP, d) * Vector3(-s * HUB_INSET, 0.0, 0.0)
		var shaft := outer - pin
		n[c + "_Driveshaft"].transform = Transform3D(
			Basis(Quaternion(Vector3.RIGHT, shaft.normalized())).scaled_local(Vector3(shaft.length(), 1.0, 1.0)), pin)
