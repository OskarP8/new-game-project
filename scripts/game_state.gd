extends Node

const SAVE_PATH : String = "user://save.tres"
const SaveDataResource := preload("res://scripts/SaveData.gd")  # <-- exact path you said

# Runtime checkpoint
var checkpoint_scene: String = ""
var checkpoint_position: Vector2 = Vector2.ZERO

# Persistent save (what's on disk / last saved)
var saved_scene: String = ""
var saved_position: Vector2 = Vector2.ZERO

func _ready() -> void:
	load_save()

func set_checkpoint(scene_path: String, pos: Vector2) -> void:
	checkpoint_scene = scene_path
	checkpoint_position = pos
	push_warning("[GameState] ✅ Checkpoint set: %s %s" % [scene_path, str(pos)])

func has_checkpoint() -> bool:
	return checkpoint_scene != ""

func get_respawn_data() -> Dictionary:
	return {"scene": checkpoint_scene, "position": checkpoint_position}

func save() -> void:
	var scene_path := ""
	var pos := Vector2.ZERO
	if has_checkpoint():
		scene_path = checkpoint_scene
		pos = checkpoint_position
	elif get_tree().current_scene:
		scene_path = get_tree().current_scene.scene_file_path
	save_game(scene_path, pos)

func has_save() -> bool:
	return saved_scene != ""

func save_game(scene_path: String = "", pos: Vector2 = Vector2.ZERO) -> void:
	if scene_path == "":
		if has_checkpoint():
			scene_path = checkpoint_scene
			pos = checkpoint_position
		elif get_tree().current_scene:
			scene_path = get_tree().current_scene.scene_file_path

	saved_scene = scene_path
	saved_position = pos

	var save_res := SaveDataResource.new()
	save_res.scene_path = saved_scene
	save_res.position = saved_position
	# keep timestamp 0 (avoid OS.* calls that triggered analyzer warnings)
	save_res.saved_at_unix = 0

	var err := ResourceSaver.save(save_res, SAVE_PATH)  # correct order: path, resource
	if err != OK:
		push_error("[GameState] Save failed: %s" % str(err))
	else:
		print("[GameState] 💾 Game saved to %s scene:%s pos:%s" % [SAVE_PATH, saved_scene, str(saved_position)])

func load_save() -> bool:
	if not FileAccess.file_exists(SAVE_PATH):
		print("[GameState] No save file found at %s" % SAVE_PATH)
		return false

	var res := ResourceLoader.load(SAVE_PATH)
	if not res:
		push_error("[GameState] Failed to load save resource at: %s" % SAVE_PATH)
		return false

	if res is SaveData:
		saved_scene = res.scene_path
		saved_position = res.position
		print("[GameState] ✅ Save loaded: %s %s" % [saved_scene, str(saved_position)])
		return true

	push_error("[GameState] Unexpected save resource type")
	return false

func get_save_data() -> Dictionary:
	return {
		"scene": saved_scene,
		"position": Vector2(saved_position.x, saved_position.y)
	}
