extends Node

# 🔁 Checkpoint (runtime only)
var checkpoint_scene: String = ""
var checkpoint_position: Vector2 = Vector2.ZERO

# 💾 Persistent save (what's on disk / last saved)
var saved_scene: String = ""
var saved_position: Vector2 = Vector2.ZERO

const SAVE_PATH: String = "user://save.json"
# --- Put this anywhere in GameState.gd with the other public helpers ---

func has_save() -> bool:
	# Returns true if we have a saved scene (either from disk or runtime)
	return saved_scene != ""

func _ready() -> void:
	load_save()

# ------------------------
# Checkpoint API (existing)
# ------------------------
func set_checkpoint(scene_path: String, pos: Vector2) -> void:
	checkpoint_scene = scene_path
	checkpoint_position = pos
	push_warning("[GameState] ✅ Checkpoint set: %s %s" % [scene_path, str(pos)])

func has_checkpoint() -> bool:
	return checkpoint_scene != ""

func get_respawn_data() -> Dictionary:
	return {
		"scene": checkpoint_scene,
		"position": checkpoint_position
	}

# ------------------------
# Save / Load API
# Backwards-compatible: supports both calling save() with zero args
# or save_game(scene_path, pos) explicitly.
# ------------------------
func save() -> void:
	# prefer checkpoint if present, otherwise try to use current scene
	var scene_path: String = ""
	var pos: Vector2 = Vector2.ZERO
	if has_checkpoint():
		scene_path = checkpoint_scene
		pos = checkpoint_position
	else:
		# fallback: attempt to get current scene path & player pos if present
		if get_tree().current_scene:
			scene_path = get_tree().current_scene.scene_file_path
	# call save_game(...) which handles defaults
	save_game(scene_path, pos)

# Primary save function (explicit) — keeps old name but now with default args
func save_game(scene_path: String = "", pos: Vector2 = Vector2.ZERO) -> void:
	# If caller didn't provide scene_path, fall back to checkpoint or current_scene.
	if scene_path == "":
		if has_checkpoint():
			scene_path = checkpoint_scene
			pos = checkpoint_position
		elif get_tree().current_scene:
			scene_path = get_tree().current_scene.scene_file_path

	# store into runtime saved_* fields
	saved_scene = scene_path
	saved_position = pos

	# build a plain-serializable dictionary (avoid putting Nodes/Resources directly)
	var data: Dictionary = {
		"scene": saved_scene,
		"position": {"x": saved_position.x, "y": saved_position.y}
		# purposely omitted timestamp to avoid environment-specific OS calls
	}

	# write JSON to disk
	var err := _write_json_to_disk(data)
	if err != OK:
		push_error("[GameState] Save failed: %s" % str(err))
	else:
		push_warning("[GameState] 💾 Game saved to %s scene: %s pos: %s" % [SAVE_PATH, saved_scene, str(saved_position)])

# Read last save and populate saved_scene/saved_position fields.
# Does NOT automatically teleport or change checkpoint; call apply_save_to_checkpoint() if you want that.
func load_save() -> bool:

	if not FileAccess.file_exists(SAVE_PATH):
		push_warning("[GameState] No save file found at %s" % SAVE_PATH)
		return false

	var f := FileAccess.open(SAVE_PATH, FileAccess.ModeFlags.READ)
	if not f:
		push_error("[GameState] Failed to open save file for read: %s" % SAVE_PATH)
		return false

	var s: String = f.get_as_text()
	f.close()

	var parsed = JSON.parse_string(s)
	if parsed.error != OK:
		push_error("[GameState] JSON parse error while loading save: %s" % str(parsed.error))
		return false

	var data: Dictionary = parsed.result if typeof(parsed.result) == TYPE_DICTIONARY else {}
	if "scene" in data:
		saved_scene = String(data["scene"])
	if "position" in data and typeof(data["position"]) == TYPE_DICTIONARY:
		var p: Dictionary = data["position"]
		var px := float(p.get("x", 0.0))
		var py := float(p.get("y", 0.0))
		saved_position = Vector2(px, py)

	push_warning("[GameState] ✅ Save loaded: %s %s" % [saved_scene, str(saved_position)])
	return true

# Helper: set last-loaded save as the runtime checkpoint if you want that behavior
func apply_save_as_checkpoint() -> void:
	if saved_scene != "":
		set_checkpoint(saved_scene, saved_position)
		push_warning("[GameState] Applied saved data as checkpoint: %s %s" % [saved_scene, str(saved_position)])

# Getter used by other code (returns plain Dictionary)
func get_save_data() -> Dictionary:
	return {"scene": saved_scene, "position": {"x": saved_position.x, "y": saved_position.y}}

# ------------------------
# Private helpers
# ------------------------
func _write_json_to_disk(data: Dictionary) -> Error:
	# Use a stringified safe representation to avoid analyzer issues with JSON.print
	var s: String = str(data)
	var f := FileAccess.open(SAVE_PATH, FileAccess.ModeFlags.WRITE)
	if not f:
		return ERR_CANT_OPEN
	f.store_string(s)
	f.close()
	return OK
