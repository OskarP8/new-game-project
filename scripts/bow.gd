extends Weapon
class_name Bow

@export var arrow_scene: PackedScene
@export var max_charge_time: float = 1.2
@export var aim_sensitivity: float = 9.0
@export var charge_aim_sensitivity: float = 11.0

var is_charging: bool = false
var charge_timer: float = 0.0
var attack_timer: float = 0.0
@export var attack_duration: float = 0.25

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
	if weapon_pivot:
		var aim_direction := get_global_mouse_position() - weapon_pivot.global_position
		if aim_direction.length_squared() > 0.0:
			var target_angle := aim_direction.angle()
			var sensitivity := charge_aim_sensitivity if is_charging else aim_sensitivity
			var blend := 1.0 - exp(-sensitivity * delta)
			weapon_pivot.rotation = lerp_angle(weapon_pivot.rotation, target_angle, blend)
			if weapon_holder:
				weapon_holder.scale.x = 1.0

			if weapon_owner:
				weapon_owner.facing_left = aim_direction.x < 0.0
				weapon_owner.bow_aiming_up = aim_direction.y < 0.0
				weapon_owner.post_attack_left = weapon_owner.facing_left
				weapon_owner.hor_dir = "left" if weapon_owner.facing_left else "right"

	_update_aim_mode()

	if is_charging:
		charge_timer = min(charge_timer + delta, max_charge_time)
	if attack_timer > 0.0:
		attack_timer -= delta
		if attack_timer <= 0.0:
			end_attack()

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

# Called by player when pressing the attack button
func start_attack() -> void:
	if attacking or is_charging:
		return
		
	is_charging = true
	charge_timer = 0.0
	
	if anim_player and anim_player.has_animation("charge"):
		anim_player.play("charge")
	elif sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("charge"):
		sprite.play("charge")

# Called by player when releasing the attack button
func release_attack() -> void:
	if not is_charging:
		return
		
	is_charging = false
	attacking = true
	attack_timer = attack_duration
	
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
	
	# Pass launch details to the arrow
	if arrow.has_method("launch"):
		arrow.launch(global_position, target_ground_pos, target_z)

func _on_anim_finished(anim_name: String) -> void:
	if anim_name.begins_with("attack"):
		end_attack()
