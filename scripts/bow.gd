extends Weapon
class_name Bow

@export var arrow_scene: PackedScene
@export var max_charge_time: float = 1.2
@export var aim_sensitivity: float = 9.0
@export var charge_aim_sensitivity: float = 11.0

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
	if is_charging and weapon_pivot:
		_update_aim(delta)
	if attacking and sprite and sprite.animation == &"attack":
		var final_frame := sprite.sprite_frames.get_frame_count(&"attack") - 1
		if sprite.frame == final_frame and sprite.frame_progress >= 0.99:
			end_attack()

	if is_charging:
		_update_aim_mode()

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
		if (parent is Enemy and parent.is_flying) or hit.collider.is_in_group("flying_enemies"):
			is_air_target = true
			target_z = parent.flight_height if parent is Enemy and "flight_height" in parent else 100.0
			target_ground_pos = hit.collider.global_position + Vector2(0, target_z)
			break

func _update_aim(delta: float, snap: bool = false) -> void:
	var aim_direction := get_global_mouse_position() - weapon_pivot.global_position
	if aim_direction.length_squared() == 0.0:
		return

	var target_angle := aim_direction.angle()
	if snap:
		weapon_pivot.rotation = target_angle
	else:
		var blend := 1.0 - exp(-charge_aim_sensitivity * delta)
		weapon_pivot.rotation = lerp_angle(weapon_pivot.rotation, target_angle, blend)

	if weapon_holder:
		weapon_holder.scale.x = 1.0

	if weapon_owner:
		weapon_owner.facing_left = aim_direction.x < 0.0
		weapon_owner.bow_aiming_up = aim_direction.y < 0.0
		weapon_owner.post_attack_left = weapon_owner.facing_left
		weapon_owner.hor_dir = "left" if weapon_owner.facing_left else "right"

# Called by player when pressing the attack button
func start_attack() -> void:
	if attacking or is_charging:
		return
	if sprite and not sprite.animation_finished.is_connected(_on_sprite_animation_finished):
		sprite.animation_finished.connect(_on_sprite_animation_finished)
		
	is_charging = true
	charge_timer = 0.0
	if weapon_owner and weapon_owner.has_method("update_layers"):
		weapon_owner.update_layers()
	_update_aim(0.0, true)
	
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("charge"):
		sprite.play("charge")
	elif anim_player and anim_player.has_animation("charge"):
		anim_player.play("charge")

# Called by player when releasing the attack button
func release_attack() -> void:
	if not is_charging:
		return
		
	is_charging = false
	attacking = true
	if weapon_owner and weapon_owner.has_method("update_layers"):
		weapon_owner.update_layers()
	
	_spawn_arrow()
	
	# Play shoot animation from the bow sprite while keeping the release angle locked.
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("attack"):
		sprite.play("attack")
	elif anim_player and anim_player.has_animation("attack"):
		anim_player.play("attack")

func end_attack() -> void:
	if not attacking:
		return
	super.end_attack()
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("idle"):
		sprite.play("idle")
	if weapon_owner and weapon_owner.has_method("update_layers"):
		weapon_owner.update_layers()

func _spawn_arrow() -> void:
	if not arrow_scene:
		push_error("[Bow] Missing arrow_scene!")
		return

	var arrow = arrow_scene.instantiate()
	get_tree().current_scene.add_child(arrow)
	
	# Pass launch details to the arrow
	if arrow.has_method("launch"):
		arrow.launch(global_position, target_ground_pos, target_z)

func _on_anim_finished(anim_name: String) -> void:
	if anim_name.begins_with("attack"):
		end_attack()

func _on_sprite_animation_finished(anim_name: StringName) -> void:
	if anim_name == &"attack":
		end_attack()
