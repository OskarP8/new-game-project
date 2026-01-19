extends CanvasLayer

func _ready():
	Engine.time_scale = 1.0

func _on_start_pressed() -> void:
	print("START pressed")

	var dd := get_tree().get_first_node_in_group("DeathDirector")
	if dd:
		dd.fade_to_scene("res://scenes/world.tscn")
	else:
		push_error("DeathDirector not found!")

func _on_quit_pressed() -> void:
	get_tree().quit()
