extends CanvasLayer
@onready var fade = $ColorRect
func _ready():
	fade.visible = false
	Engine.time_scale = 1.0

func _on_start_pressed() -> void:
	print("START pressed")
	var anim: AnimationPlayer = $AnimationPlayer
	fade.visible = true
	anim.play("intro")
	get_tree().change_scene_to_file("res://scenes/world.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()
