extends Area2D

@export var activate_once := true
var activated := false

func _on_body_entered(body):
	if body.name != "Player":
		return

	if GameState.checkpoint_position == global_position:
		return  # Already active

	GameState.set_checkpoint(
		get_tree().current_scene.scene_file_path,
		global_position
	)

	# Optional feedback
	if has_node("AnimationPlayer"):
		$AnimationPlayer.play("activate")
