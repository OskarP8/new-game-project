# weapon.gd
extends Node2D
class_name Weapon

# --- CONFIG ---
@export var damage: int = 10
@export var knockback_force: float = 120.0
@export var hitbox_name: String = "Hitbox"
@export var anim_player_name: String = "AnimationPlayer"
@export var grip_node_name: String = "Grip"

# --- RUNTIME ---
var weapon_owner: Node = null
var attacking: bool = false

# --- CHILD REFERENCES ---
@onready var anim_player: AnimationPlayer = get_node_or_null(anim_player_name)
@onready var hitbox: Area2D = get_node_or_null(hitbox_name)
@onready var grip_node: Node2D = get_node_or_null(grip_node_name)

signal attack_finished()

func _ready() -> void:
	# Disable hitbox at start
	if hitbox:
		hitbox.monitoring = false
		if not hitbox.is_connected("body_entered", Callable(self, "_on_Hitbox_body_entered")):
			hitbox.body_entered.connect(Callable(self, "_on_Hitbox_body_entered"))

	# Auto-align weapon so GRIP = (0,0)
	if grip_node:
		position = -grip_node.position

	# Connect animation finished
	if anim_player:
		if not anim_player.is_connected("animation_finished", Callable(self, "_on_anim_finished")):
			anim_player.animation_finished.connect(Callable(self, "_on_anim_finished"))


# Called by player/enemy after instancing
func setup(owner: Node) -> void:
	weapon_owner = owner

# Start attack (enemy or player)
func start_attack() -> void:
	if attacking:
		return

	attacking = true

	if hitbox:
		hitbox.monitoring = true

	if anim_player and anim_player.has_animation("attack"):
		anim_player.play("attack")
	else:
		# fallback if no animation
		await get_tree().create_timer(0.25).timeout
		finish_attack()


func finish_attack() -> void:
	if not attacking:
		return

	attacking = false

	if hitbox:
		hitbox.monitoring = false

	if anim_player and anim_player.is_playing():
		anim_player.stop()

	emit_signal("attack_finished")


# Alias for animation CallMethod tracks
func end_attack() -> void:
	finish_attack()


# AnimationPlayer callback
func _on_anim_finished(anim_name: String) -> void:
	if anim_name.begins_with("attack"):
		finish_attack()


# Hitbox callback
func _on_Hitbox_body_entered(body: Node) -> void:
	if not attacking:
		return

	if body == weapon_owner:
		return

	# Apply damage
	if body.has_method("take_damage"):
		body.take_damage(damage, global_position)

	# Knockback
	if body.has_method("external_knockback"):
		var dir = (body.global_position - global_position).normalized()
		body.external_knockback(dir * knockback_force)
