# Enemy.gd
extends CharacterBody2D
class_name Enemy

# --- Stats ---
@export var max_hp: int = 10
@export var speed: float = 60.0
@export var notice_radius: float = 120.0   # short radius for first notice
@export var chase_radius: float = 220.0    # larger radius used while chasing
@export var attack_range: float = 24.0
@export var attack_cooldown: float = 1.0
@export var knockback_strength: float = 120.0
@export var detection_rays: int = 16       # number of rays to cast around
@export var detection_interval: float = 0.12

# Scenes / resources
@export var loot_table: Array = [] # array of PackedScene or InvItem resources for drops
@export var world_item_scene: PackedScene = preload("res://scenes/world_item.tscn")

# Nodes
@onready var agent: NavigationAgent2D = $Agent
@onready var sprite: AnimatedSprite2D = $Sprite

# State
enum {
	IDLE,
	ALERT,
	CHASE,
	SEARCH,
	ATTACK,
	FLEE,
	DEAD
}
var state = IDLE
var hp: int
var player: Node = null
var last_seen_pos: Vector2 = Vector2.ZERO
var detection_timer: float = 0.0
var attack_timer: float = 0.0
var search_timer: float = 0.0
var search_duration: float = 2.0
var velocity_vec: Vector2 = Vector2.ZERO

# Signals for global effects
signal enemy_hit_player(damage)
signal enemy_damaged(amount)
signal enemy_died()

func _ready() -> void:
	hp = max_hp
	player = get_tree().get_root().find_child("Player", true, false)
	agent.velocity_computed.connect(Callable(self, "_on_agent_velocity"))
	agent.target_desired_distance = 4.0
	agent.path_max_lookahead_distance = 64.0
	set_physics_process(true)

func _physics_process(delta: float) -> void:
	# timers
	detection_timer -= delta
	attack_timer = max(0.0, attack_timer - delta)

	match state:
		IDLE:
			_process_idle(delta)
		ALERT:
			_process_alert(delta)
		CHASE:
			_process_chase(delta)
		SEARCH:
			_process_search(delta)
		ATTACK:
			# attack handled inside _process_chase or by subclass when in range
			pass
		FLEE:
			_process_flee(delta)
		DEAD:
			pass

	# move
	if velocity_vec.length_squared() > 0:
		velocity = velocity_vec
		move_and_slide()
	else:
		velocity = Vector2.ZERO

# ------------------------------
# State machines
# ------------------------------
func _process_idle(delta: float) -> void:
	# periodically scan for player
	if _scan_for_player(notice_radius):
		state = ALERT
		return
	# idle wandering could be placed here

func _process_alert(delta: float) -> void:
	# once alerted, immediately transition to chase
	if player:
		last_seen_pos = player.global_position
		state = CHASE

func _process_chase(delta: float) -> void:
	# continue scanning with a larger radius while chasing
	if player:
		if _scan_for_player(chase_radius):
			# update last seen and set agent to the player's position
			last_seen_pos = player.global_position
			agent.set_target_location(player.global_position)
		else:
			# lost sight — switch to SEARCH
			state = SEARCH
			search_timer = search_duration
			agent.set_target_location(last_seen_pos)
			return

		# if within attack range -> attack
		var dist_to_player = global_position.distance_to(player.global_position)
		if dist_to_player <= attack_range and attack_timer <= 0.0:
			state = ATTACK
			_perform_attack()
			return

		# path-following: agent handles pathing; velocity is filled in agent callback
		# nothing else here; agent velocity will be applied in _on_agent_velocity

func _process_search(delta: float) -> void:
	# move to last seen pos, then look around for a bit
	search_timer -= delta
	# if we can re-see the player while searching, resume chase
	if _scan_for_player(chase_radius):
		state = CHASE
		return
	if search_timer <= 0.0:
		# give up and return to idle
		state = IDLE
		agent.set_target_location(global_position)

func _process_flee(delta: float) -> void:
	# example: run directly away from player while pathfinding around obstacles
	if not player:
		state = IDLE
		return
	var away_dir = (global_position - player.global_position).normalized()
	var flee_target = global_position + away_dir * 120.0
	agent.set_target_location(flee_target)
	# continue scanning for close threats and optionally attack while fleeing

# ------------------------------
# Detection helpers (raycasts)
# ------------------------------
func _scan_for_player(radius: float) -> bool:
	# only check at interval to save performance
	if detection_timer > 0.0:
		return false
	detection_timer = detection_interval

	if not player:
		return false

	var space := get_world_2d().direct_space_state
	var origin = global_position
	var angle_step = TAU / float(detection_rays)
	for i in detection_rays:
		var a = i * angle_step
		var dir = Vector2(cos(a), sin(a))
		var to = origin + dir * radius
		var query := PhysicsRayQueryParameters2D.create(origin, to)
		query.exclude = [self]
		query.collide_with_areas = true
		query.collide_with_bodies = true

		var res = space.intersect_ray(query)

		if res:
			var collider = res.collider
			# if we hit the player and no obstacle in between -> detected
			if collider and collider.is_in_group("Player"):
				# debug: print detection
				#print("[Enemy] detected player via ray", i, "at dist", origin.distance_to(res.position))
				return true
			# if we hit something else (wall), this ray is blocked
	# not detected
	return false

# ------------------------------
# Agent velocity callback
# ------------------------------
func _on_agent_velocity(safe_velocity: Vector2) -> void:
	# apply agent velocity, but clamp to speed
	if state in [CHASE, SEARCH, FLEE]:
		velocity_vec = safe_velocity.limit_length(speed)
	else:
		velocity_vec = Vector2.ZERO

# ------------------------------
# Attack (override in ranged/melee subclasses)
# ------------------------------
func _perform_attack() -> void:
	# generic melee: apply damage if close enough, then cooldown
	if not player:
		state = IDLE
		return

	# Face player — you can rotate sprite or flip
	sprite.flip_h = player.global_position.x < global_position.x

	# deal damage to player (emit a signal so camera/UI can react)
	var dmg := 1
	emit_signal("enemy_hit_player", dmg)
	# if player has method to receive damage:
	if player.has_method("apply_damage"):
		player.apply_damage(dmg)
	# knockback
	_apply_knockback_to(player, knockback_strength)
	attack_timer = attack_cooldown
	# after attack, resume chase but wait small cooldown
	state = CHASE

# ------------------------------
# Damage / death
# ------------------------------
func take_damage(amount: int, source_pos: Vector2=Vector2.ZERO, knockback_mult: float = 1.0) -> void:
	hp -= amount
	emit_signal("enemy_damaged", amount)
	# small camera effect: could connect elsewhere
	if hp <= 0 and state != DEAD:
		_die()
	else:
		# small stun/knockback
		_apply_knockback_from(source_pos, knockback_strength * knockback_mult)

func _apply_knockback_from(source_pos: Vector2, strength: float) -> void:
	var dir = (global_position - source_pos).normalized()
	velocity_vec = dir * strength

func _apply_knockback_to(target: Node, strength: float) -> void:
	if not target:
		return
	if target.has_method("apply_knockback"):
		target.apply_knockback((target.global_position - global_position).normalized() * strength)
	# else we try to directly move the target if CharacterBody2D
	elif target is CharacterBody2D:
		# a simple impulse (may be improved by sending a signal)
		target.velocity = (target.global_position - global_position).normalized() * strength

func _die() -> void:
	state = DEAD
	# play death animation if available
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("death"):
		sprite.play("death")
		# optionally wait for animation via await
	# spawn loot
	_spawn_loot()
	emit_signal("enemy_died")
	queue_free()

func _spawn_loot() -> void:
	# pick random from loot_table
	if loot_table.size() == 0:
		return
	var pick = randi() % loot_table.size()
	var item_res = loot_table[pick]
	# if it's a PackedScene of WorldItem (or an InvItem resource), try to spawn world item
	if world_item_scene and is_instance_valid(world_item_scene):
		var world_item = world_item_scene.instantiate()
		# prefer item resource assignment if 'item' property exists
		if "item" in world_item:
			world_item.item = item_res
			world_item.quantity = 1
		world_item.global_position = global_position
		get_tree().current_scene.add_child(world_item)
	else:
		# fallback: try to print or add other handling
		print("[Enemy] dropped:", item_res)
