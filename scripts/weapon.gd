extends Node2D
class_name Weapon

@export var damage: int = 10
@export var knockback: float = 80.0
@export var weapon_owner: Node2D      # Player or Enemy
@export var auto_rotate := true       # for sword swings
@export var hitbox_active := false

@onready var hitbox: Area2D = $Area2D

func _ready():
	set_process(false)
	hitbox.monitoring = false
	hitbox.area_entered.connect(_on_hitbox_entered)

# Called by owner when attack begins
func start_attack():
	hitbox.monitoring = true
	hitbox_active = true
	set_process(true)

# Called by owner when attack ends
func end_attack():
	hitbox.monitoring = false
	hitbox_active = false
	set_process(false)

func _process(delta):
	# Optional: follow owner's direction
	if auto_rotate and owner:
		look_at(owner.global_position + owner.velocity)

func _on_hitbox_entered(area):
	if not hitbox_active:
		return

	var target = area.get_parent()
	if target == owner:
		return

	# Player hitting an enemy
	if target.has_method("take_damage"):
		target.take_damage(damage, owner.global_position)

	# Enemy hitting player
	if target.has_method("apply_damage"):
		target.apply_damage(damage)
