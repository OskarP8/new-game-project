extends CanvasLayer

@onready var resume_button := $VBoxContainer/Resume  # adjust path

func _ready():
	Engine.time_scale = 1.0

	if not GameState.has_save():
		resume_button.visible = false
		resume_button.disabled = true

func _on_start_pressed() -> void:
	print("NEW GAME pressed")

	# Clear runtime + save data
	GameState.checkpoint_scene = ""
	GameState.saved_scene = ""

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

	var dd := get_tree().get_first_node_in_group("DeathDirector")
	if dd:
		dd.fade_to_scene(data.scene)

		# Tell DeathDirector to apply SAVE, not checkpoint
		dd.set_pending_spawn_position(data.position)
