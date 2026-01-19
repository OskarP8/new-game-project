extends Node

# 🔁 Checkpoint (runtime only)
var checkpoint_scene: String = ""
var checkpoint_position: Vector2 = Vector2.ZERO

# 💾 Persistent save
var saved_scene: String = ""
var saved_position: Vector2 = Vector2.ZERO

func set_checkpoint(scene_path: String, pos: Vector2):
	checkpoint_scene = scene_path
	checkpoint_position = pos
	print("[GameState] ✅ Checkpoint set:", scene_path, pos)

func has_checkpoint() -> bool:
	return checkpoint_scene != ""

func get_respawn_data():
	return {
		"scene": checkpoint_scene,
		"position": checkpoint_position
	}

func save_game(scene_path: String, pos: Vector2):
	saved_scene = scene_path
	saved_position = pos
	print("[GameState] 💾 Game saved")

func has_save() -> bool:
	return saved_scene != ""

func get_save_data():
	return {
		"scene": saved_scene,
		"position": saved_position
	}
