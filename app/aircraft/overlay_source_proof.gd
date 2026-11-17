extends RefCounted
## Versioned source-input proofs for the separately registered overlays.
## Packaged proofs identify exporter inputs, not compiled bytecode.
const Registry := preload("res://aircraft/model_registry.gd")
const PROOF_SOURCE := "assets/aircraft/moonrunner-x99-overlay/runtime-proof.json"
const SOURCE_PATHS := [
	"assets/aircraft/moonrunner-x99-overlay/customization-bindings.json",
	"assets/aircraft/moonrunner-x99-overlay/model-bindings.json",
	"res://aircraft/customization_overlay.gd",
	"res://aircraft/model_manifest.gd",
	"res://aircraft/model_overlay_registry.gd",
	"res://aircraft/model_registry.gd",
	"res://aircraft/overlay_source_proof.gd",
]
const FORMAT := "openrc-moonrunner-overlay-source-proof"

const ELECTRIC_FAMILY := "stik-electric-6s"
const ELECTRIC_PROOF_SOURCE := "assets/aircraft/stik-electric-6s/runtime-proof.json"
const ELECTRIC_SOURCE_PATHS := [
	"assets/aircraft/stik-electric-6s/customization-bindings.json",
	"assets/aircraft/stik-electric-6s/model-bindings.json",
	"res://aircraft/customization_overlay.gd",
	"res://aircraft/model_manifest.gd",
	"res://aircraft/model_overlay_registry.gd",
	"res://aircraft/model_registry.gd",
	"res://aircraft/overlay_source_proof.gd",
]

const TWIN_BOOM_FAMILY := "twin-boom-1800"
const TWIN_BOOM_PROOF_SOURCE := "assets/aircraft/twin-boom-1800/runtime-proof.json"
const TWIN_BOOM_SOURCE_PATHS := [
	"assets/aircraft/twin-boom-1800/customization-bindings.json",
	"assets/aircraft/twin-boom-1800/model-bindings.json",
	"res://aircraft/customization_overlay.gd",
	"res://aircraft/model_manifest.gd",
	"res://aircraft/model_overlay_registry.gd",
	"res://aircraft/model_registry.gd",
	"res://aircraft/overlay_source_proof.gd",
]

const FAST_DELTA_FAMILY := "fast-delta-780"
const FAST_DELTA_PROOF_SOURCE := "assets/aircraft/fast-delta-780/runtime-proof.json"
const FAST_DELTA_SOURCE_PATHS := [
	"assets/aircraft/fast-delta-780/customization-bindings.json",
	"assets/aircraft/fast-delta-780/model-bindings.json",
	"res://aircraft/customization_overlay.gd",
	"res://aircraft/model_manifest.gd",
	"res://aircraft/model_overlay_registry.gd",
	"res://aircraft/model_registry.gd",
	"res://aircraft/overlay_source_proof.gd",
]

static func source_paths(family: String) -> Array:
	if family == "moonrunner-x99": return SOURCE_PATHS
	if family == ELECTRIC_FAMILY: return ELECTRIC_SOURCE_PATHS
	if family == TWIN_BOOM_FAMILY: return TWIN_BOOM_SOURCE_PATHS
	if family == FAST_DELTA_FAMILY: return FAST_DELTA_SOURCE_PATHS
	return []

static func _proof_source(family: String) -> String:
	if family == ELECTRIC_FAMILY: return ELECTRIC_PROOF_SOURCE
	if family == TWIN_BOOM_FAMILY: return TWIN_BOOM_PROOF_SOURCE
	if family == FAST_DELTA_FAMILY: return FAST_DELTA_PROOF_SOURCE
	return PROOF_SOURCE

static func _proof_format(family: String) -> String:
	if family in [ELECTRIC_FAMILY, TWIN_BOOM_FAMILY, FAST_DELTA_FAMILY]: return "openrc-%s-overlay-source-proof" % family
	return FORMAT

static func verify(manifest: Dictionary, family: String = "moonrunner-x99") -> Dictionary:
	var paths := source_paths(family)
	if paths.is_empty(): return _failure("Unknown overlay source proof family.")
	var proof_source := _proof_source(family)
	var proof_format := _proof_format(family)
	var record := {}
	for item: Variant in manifest.get("authoring_sources", []):
		if item is Dictionary and item.get("path") == proof_source and item.get("role") == "overlay_runtime_proof":
			if not record.is_empty(): return _failure("Overlay source proof is duplicated.")
			record = item
	if record.is_empty(): return _failure("Overlay source proof is missing from the model manifest.")
	var package: Dictionary = Registry._read_package_proofs()
	if not package.get("ok", false): return package
	var files: Dictionary = package.get("files", {})
	var proof_bytes := _read_source(proof_source, files)
	if proof_bytes.is_empty() or _sha256_lf(proof_bytes) != str(record.get("sha256", "")):
		return _failure("Overlay source proof bytes are missing or changed.")
	var proof: Variant = JSON.parse_string(proof_bytes.get_string_from_utf8())
	if not proof is Dictionary or proof.size() != 3 or not proof.has_all(["format", "version", "sources"]) \
			or proof.format != proof_format or typeof(proof.version) not in [TYPE_INT, TYPE_FLOAT] \
			or proof.version != 1 or not proof.sources is Array or proof.sources.size() != paths.size():
		return _failure("Overlay source proof is malformed or unsupported.")
	for index in paths.size():
		var item: Variant = proof.sources[index]
		var source: String = paths[index]
		if not item is Dictionary or item.size() != 2 or not item.has_all(["path", "sha256"]) \
				or item.path != source or not _valid_sha(str(item.sha256)):
			return _failure("Overlay source proof has unknown or malformed source records.")
		var bytes := _read_source(source, files)
		if bytes.is_empty() or _sha256_lf(bytes) != str(item.sha256):
			return _failure("Overlay source is missing or changed: " + source)
		if source.begins_with("res://") and not files.is_empty() \
				and (not ResourceLoader.exists(source) or ResourceLoader.load(source) == null):
			return _failure("Packaged overlay script is unavailable: " + source)
	return {"ok": true, "errors": PackedStringArray()}

static func _read_source(source: String, files: Dictionary) -> PackedByteArray:
	var path := ""
	if not files.is_empty():
		path = str(files.get(source, ""))
	elif source.begins_with("res://"):
		path = source
	else:
		path = ProjectSettings.globalize_path("res://").path_join("../" + source)
	return FileAccess.get_file_as_bytes(path) if not path.is_empty() and FileAccess.file_exists(path) else PackedByteArray()

static func _sha256_lf(bytes: PackedByteArray) -> String:
	var text := bytes.get_string_from_utf8().replace("\r\n", "\n")
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(text.to_utf8_buffer())
	return hash.finish().hex_encode()

static func _valid_sha(value: String) -> bool:
	if value.length() != 64: return false
	for character in value:
		if not "0123456789abcdef".contains(character): return false
	return true

static func _failure(message: String) -> Dictionary:
	return {"ok": false, "errors": PackedStringArray([message])}
