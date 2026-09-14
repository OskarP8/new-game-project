extends Weapon
class_name Bow

@export var arrow_scene: PackedScene
@export var max_charge_time: float = 1.2

var is_charging: bool = false
var charge_timer: float = 0.0

# Target tracking for height mode
var is_air_target: bool = false
var target_ground_pos: Vector2 = Vector2.ZERO
var target_z: float = 0.0

func _ready():
	# Ensure the bow's melee hitbox never triggers hits directly
	if hitbox:
		hitbox.monitoring = false
		hitbox.monitorable = false

func update_weapon(delta: float) -> void:
	# Keep standard rotation / pivot logic from Weapon
	super.update_weapon(delta)
	
	# Update aiming & target altitude checks every frame
	_update_aim_mode()

	# Charge logic
	if is_charging:
		charge_timer = min(charge_timer + delta, max_charge_time)

func _update_aim_mode() -> void:
	var mouse_pos = get_global_mouse_position()
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsPointQueryParameters2D.new()
	query.position = mouse_pos
	query.collide_with_areas = true
	
	var hits = space_state.intersect_point(query)
	
	is_air_target = false
	target_ground_pos = mouse_pos
	target_z = 0.0
	
	for hit in hits:
		var parent = hit.collider.get_parent()
		if parent is FlyingEnemy or hit.collider.is_in_group("flying_enemies"):
			is_air_target = true
			target_z = parent.flight_height if "flight_height" in parent else 100.0
			target_ground_pos = hit.collider.global_position + Vector2(0, target_z)
			break

# Called by player when pressing the attack button
func start_attack() -> void:
	if attacking or is_charging:
		return
		
	is_charging = true
	charge_timer = 0.0
	
	if anim_player and anim_player.has_animation("draw_bow"):
		anim_player.play("draw_bow")
	elif sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("draw"):
		sprite.play("draw")

# Called by player when releasing the attack button
func release_attack() -> void:
	if not is_charging:
		return
		
	is_charging = false
	attacking = true
	
	_spawn_arrow()
	
	# Play shoot animation
	if anim_player and anim_player.has_animation("attack"):
		anim_player.play("attack")
	elif sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("attack"):
		sprite.play("attack")

func _spawn_arrow() -> void:
	if not arrow_scene:
		push_error("[Bow] Missing arrow_scene!")
		return

	var arrow = arrow_scene.instantiate()
	get_tree().current_scene.add_child(arrow)
	
	var charge_ratio = clamp(charge_timer / max_charge_time, 0.3, 1.0)
	
	# Pass launch details to the arrow
	arrow.launch(global_position, target_ground_pos, target_z)

func _on_anim_finished(anim_name: String) -> void:
	if anim_name.begins_with("attack"):
		end_attack()
