extends Enemy
class_name Knight

func _ready():
	super._ready()

	# Knight-specific stats
	max_hp = 16
	speed = 70.0
	attack_damage = 8
	knockback_strength = 130.0
	attack_range = 26.0
	attack_cooldown = 1.1

	# Optional: knight uses slightly slower but stronger slashes
