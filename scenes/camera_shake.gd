extends Camera2D

var shake_time := 0.0
var shake_strength := 0.0

func shake(strength: float, time: float):
	shake_strength = strength
	shake_time = time
	print("[CAMERA] shake start", strength, time)

func _process(delta):
	if shake_time > 0.0:
		shake_time -= delta

		offset = Vector2(
			randf_range(-shake_strength, shake_strength),
			randf_range(-shake_strength, shake_strength)
		)
	else:
		offset = Vector2.ZERO
