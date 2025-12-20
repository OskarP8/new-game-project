extends Camera2D
class_name CameraShake

@export var trauma_decay: float = 6.0

var trauma: float = 0.0
var max_offset := Vector2(12, 8)
var max_rotation := 0.04

func add_trauma(amount: float) -> void:
	trauma = clamp(trauma + amount, 0.0, 1.0)

func _process(delta: float) -> void:
	if trauma <= 0.0:
		offset = Vector2.ZERO
		rotation = 0.0
		return

	trauma = max(trauma - trauma_decay * delta, 0.0)
	var t := trauma * trauma

	offset = Vector2(
		randf_range(-1, 1) * max_offset.x * t,
		randf_range(-1, 1) * max_offset.y * t
	)

	rotation = randf_range(-1, 1) * max_rotation * t
