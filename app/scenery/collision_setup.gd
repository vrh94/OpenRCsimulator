## LU-05: one scenery/lighting visibility policy for the flight collision inventory.
## Builds before the session enters the tree. No scene traversal occurs in the physics tick.
extends RefCounted
const Scenery := preload("res://scenery/scenery.gd")
const Loader := preload("res://scenery/scenery_loader.gd")
const FieldLights := preload("res://render/world/field_lights.gd")
const CollisionWorld := preload("res://scenery/collision_world.gd")

## `rc_track`: the validated RC-TRACK circuit of this airplane flight, or {} (scenery/rc_track_option.gd).
## A field with solid terrain (a `terrain` block) takes its obstacles from its own landscape adapter, the same one that
## draws it (render/field.gd), so the FPV quad and the blimp collide with the surveyed trees and buildings they see.
static func build(field: Dictionary, rc_track: Dictionary = {}) -> Dictionary:
	if field.has("terrain"):
		# Loaded at run time: the club landscape adapter itself builds through here.
		var catalog: Script = load("res://landscapes/catalog.gd")
		var id := str(field.get("id", ""))
		if not catalog.has(id):
			return {ok = false, world = {}, errors = PackedStringArray(["field '%s' has terrain but no landscape adapter supplies its obstacles" % id])}
		return catalog.collision_world(id, field, rc_track)
	var scenery := {groups = []}
	var opts := Scenery.options()
	if opts.enabled and Scenery.layout_file_applies(field, opts):
		var loaded := Loader.load_from(str(opts.file), field)
		if not loaded.ok:
			return {ok = false, world = {}, errors = loaded.errors}
		scenery = loaded.scenery.duplicate(true)
	var lights := {}
	# Fixture structures remain visible and physical even when their emitters are off.
	if field.get("id", "") == "default":
		var loaded := FieldLights.load_from()
		if not loaded.ok:
			return {ok = false, world = {}, errors = loaded.errors}
		lights = loaded.lights
	return CollisionWorld.build(field, scenery, lights, rc_track)
