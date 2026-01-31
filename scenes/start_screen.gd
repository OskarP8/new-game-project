extends CanvasLayer

@onready var resume_button := $VBoxContainer/Resume  # adjust path

func _ready():
	Engine.time_scale = 1.0

	# Ensure GameState has loaded any on-disk save so has_save() is accurate.
	if has_node("/root/GameState") and GameState.has_method("load_save"):
		GameState.load_save()

	# Now check for save presence
	if not GameState.has_save():
		resume_button.visible = false
		resume_button.disabled = true

func _on_start_pressed() -> void:
	print("NEW GAME pressed")

	# Clear runtime + saved data (overwrite the old save with a fresh start).
	# This will make "Continue" disappear next time unless the player saves later.
	if has_node("/root/GameState"):
		GameState.checkpoint_scene = ""
		GameState.saved_scene = ""
		GameState.saved_position = Vector2.ZERO
		# Persist this cleared state: save the world start scene as the saved scene
		# so pressing resume later doesn't resurrect the old save.
		# If you prefer to fully delete the file, you can implement removal in GameState.
		var start_scene := "res://scenes/world.tscn" # change if your gameplay scene path differs
		GameState.save_game(start_scene, Vector2.ZERO)

	var dd := get_tree().get_first_node_in_group("DeathDirector")
	if dd:
		dd.fade_to_scene("res://scenes/world.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()

func _on_resume_pressed() -> void:
	print("CONTINUE pressed")

	if not GameState.has_save():
		return

	var data = GameState.get_save_data()

	# data.position may be a Dictionary {"x", "y"} or a Vector2 depending on your GameState implementation.
	var pos: Vector2 = Vector2.ZERO
	if typeof(data.position) == TYPE_DICTIONARY:
		var p = data.position
		pos = Vector2(p.get("x", 0.0), p.get("y", 0.0))
	elif typeof(data.position) == TYPE_VECTOR2:
		pos = data.position
	else:
		# defensive fallback
		pos = Vector2.ZERO

	var dd := get_tree().get_first_node_in_group("DeathDirector")
	if dd:
		dd.fade_to_scene(data.scene)

		# Tell DeathDirector to apply SAVE, not checkpoint
		if dd.has_method("set_pending_spawn_position"):
			dd.set_pending_spawn_position(pos)
		else:
			push_error("[StartScreen] DeathDirector missing set_pending_spawn_position")
