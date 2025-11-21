extends CharacterBody2D
class_name Enemy

# --- Stats ---
@export var max_hp: int = 10
@export var speed: float = 60.0
@export var notice_radius: float = 120.0
@export var chase_radius: float = 220.0
@export var attack_range: float = 24.0
@export var attack_damage: int = 10
@export var attack_cooldown: float = 1.0
@export var knockback_strength: float = 120.0
@export var detection_rays: int = 16
@export var detection_interval: float = 0.12

# Scenes / resources
@export var loot_table: Array = []
@export var world_item_scene: PackedScene = preload("res://scenes/world_item.tscn")

# Nodes (ensure these paths exist in the enemy scene)
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
var state: int = IDLE
var hp: int
var player: Node = null
var last_seen_pos: Vector2 = Vector2.ZERO

# timers / motion
var detection_timer: float = 0.0
var attack_timer: float = 0.0
var search_timer: float = 0.0
var search_duration: float = 2.0
var velocity_vec: Vector2 = Vector2.ZERO

# sight smoothing / memory
var time_since_seen: float = 0.0
var lose_sight_delay: float = 0.8
var frames_required: int = 6
var frames_seen: int = 0
var frames_not_seen: int = 0

# raycast eye offset
@export var eye_offset: Vector2 = Vector2(0, -8)

# Signals
signal enemy_hit_player(damage)
signal enemy_damaged(amount)
signal enemy_died()

# Debug
var _debug_enabled: bool = true

# ------------------------------
# Helpers: animation / state
# ------------------------------
func _set_state(new_state: int) -> void:
	if state == new_state:
		return
	var old_state: int = state
	state = new_state
	if _debug_enabled:
		print("[Enemy] state:", old_state, "->", new_state, " pos:", global_position)
	match state:
		IDLE:
			_play_anim_if_exists("idle")
		ALERT:
			_play_anim_if_exists("alert")
		CHASE:
			_play_anim_if_exists("walk")
		SEARCH:
			_play_anim_if_exists("search")
		ATTACK:
			_play_anim_if_exists("attack")
		FLEE:
			_play_anim_if_exists("flee")
		DEAD:
			_play_anim_if_exists("death")

func _play_anim_if_exists(name: String) -> void:
	if not sprite:
		return
	if sprite.sprite_frames and sprite.sprite_frames.has_animation(name):
		sprite.play(name)
		if _debug_enabled:
			print("[Enemy] playing anim:", name)
	else:
		if _debug_enabled:
			print("[Enemy] anim not found:", name, " available:", sprite.sprite_frames.get_animation_names() if sprite and sprite.sprite_frames else "none")

# ------------------------------
# Lifecycle
# ------------------------------
func _ready() -> void:
	hp = max_hp

	# Find player
	var players: Array = get_tree().get_nodes_in_group("Player")
	if players.size() > 0:
		player = players[0]
	else:
		player = null

	# ---- ADD THIS BLOCK ----
	if agent:
		# Force the agent to use the correct navigation map
		var nav_map = get_world_2d().navigation_map
		agent.navigation_map = nav_map
		agent.path_desired_distance = 2.0
		agent.target_desired_distance = 2.0
	# ------------------------

	# nav agent hookup
	if agent:
		var callable := Callable(self, "_on_agent_velocity")
		if agent.velocity_computed.is_connected(callable):
			agent.velocity_computed.disconnect(callable)
		agent.velocity_computed.connect(callable)

	_play_anim_if_exists("idle")
	_set_state(IDLE)
	set_physics_process(true)

# ------------------------------
# Physics loop
# ------------------------------
func _physics_process(delta: float) -> void:
	detection_timer = max(0.0, detection_timer - delta)
	attack_timer = max(0.0, attack_timer - delta)
	if agent and _debug_enabled:
		print("agent.is_target_reachable(): ", agent.is_target_reachable())

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
			_process_attack_state(delta)
		FLEE:
			_process_flee(delta)
		DEAD:
			pass

	# apply movement
	if velocity_vec.length_squared() > 0.0001:
		velocity = velocity_vec
		move_and_slide()
	else:
		velocity = Vector2.ZERO

# ------------------------------
# State behaviours
# ------------------------------
func _process_idle(delta: float) -> void:
	if _scan_for_player(notice_radius):
		_set_state(ALERT)
		return

func _process_alert(delta: float) -> void:
	if player:
		last_seen_pos = player.global_position
		if agent:
			agent.target_position = last_seen_pos
		_set_state(CHASE)

# ------------------------------
# Chase state (replace your existing _process_chase)
# ------------------------------
func _process_chase(delta: float) -> void:
	if not player:
		_set_state(IDLE)
		if _debug_enabled:
			print("[Enemy DEBUG] No player found -> IDLE")
		return
	if agent:
		print("Reachable:", agent.is_target_reachable(), " Has Path:", agent.is_navigation_finished())
	# scan for player and maintain smoothing
	var seen: bool = _scan_for_player(chase_radius)
	if seen:
		frames_seen += 1
		frames_not_seen = 0
	else:
		frames_seen = 0
		frames_not_seen += 1

	# When we're confident we see the player, update last_seen and keep agent targetting the player
	if frames_seen >= frames_required:
		last_seen_pos = player.global_position
		if agent:
			# set the agent target every frame while seen (keeps chasing moving player)
			agent.target_position = last_seen_pos
		time_since_seen = 0.0
	else:
		# count up to decide we lost sight
		time_since_seen += delta
		if frames_not_seen >= frames_required or time_since_seen >= lose_sight_delay:
			_set_state(SEARCH)
			search_timer = search_duration
			if agent:
				agent.target_position = last_seen_pos
			if _debug_enabled:
				print("[Enemy DEBUG] Lost sight → SEARCH. Last seen:", last_seen_pos)
			return

	# Attack if close enough
	var dist_to_player: float = global_position.distance_to(player.global_position)
	if dist_to_player <= attack_range and attack_timer <= 0.0:
		_set_state(ATTACK)
		return

	# Move using navigation / fallback towards agent.target_position
	_update_agent_movement()
	if _debug_enabled:
		print("[Enemy DEBUG] Following player -> agent.target_position:", agent.target_position, " nav_finished:", agent.is_navigation_finished())

func _process_search(delta: float) -> void:
	search_timer -= delta

	# Try to detect player while searching
	if _scan_for_player(chase_radius):
		_set_state(CHASE)
		return

	# Move toward last known position
	if agent:
		agent.target_position = last_seen_pos

	_update_agent_movement()

	# If we reached the last known position, wait a bit then return to IDLE
	if agent.is_navigation_finished():
		if _debug_enabled:
			print("[Enemy DEBUG] Search reached last known pos. Timer:", search_timer)
		if search_timer <= 0.0:
			_set_state(IDLE)
			return

func _process_attack_state(delta: float) -> void:
	if attack_timer <= 0.0:
		_perform_attack()
		return
	if sprite and player:
		sprite.flip_h = player.global_position.x < global_position.x

func _process_flee(delta: float) -> void:
	if not player:
		_set_state(IDLE)
		return
	var away_dir: Vector2 = (global_position - player.global_position)
	if away_dir.length() == 0:
		away_dir = Vector2.RIGHT
	var flee_target: Vector2 = global_position + away_dir.normalized() * 120.0
	if agent:
		agent.target_position = flee_target
	_update_agent_movement()

# ------------------------------
# Agent movement helper
# ------------------------------
# ------------------------------
# Agent movement helper (replace your existing _update_agent_movement)
# ------------------------------
func _update_agent_movement() -> void:
	# no agent -> no movement
	if not agent:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			print("[Enemy DEBUG] No agent present")
		return

	# quick guard: if nav thinks it's finished, we may still want to walk directly to target (small tolerance)
	if agent.is_navigation_finished():
		# agent thinks it's at the destination; ensure the real distance is within desired tolerance
		var dist_to_target = global_position.distance_to(agent.target_position)
		if dist_to_target > agent.target_desired_distance + 2.0:
			# treat as not finished and head straight for target_position
			if _debug_enabled:
				print("[Enemy DEBUG] Agent said finished but distance is", dist_to_target, "-> heading straight to target_position")
			var dir_direct = (agent.target_position - global_position)
			velocity_vec = dir_direct.normalized() * speed if dir_direct.length() > 0.01 else Vector2.ZERO
		else:
			velocity_vec = Vector2.ZERO
			if _debug_enabled:
				print("[Enemy DEBUG] Agent navigation finished; at target (dist:", dist_to_target, ")")
		return

	# Try to get a usable next path position (get_next_location preferred fallback)
	var next_pos: Vector2 = Vector2.ZERO
	if agent.has_method("get_next_path_position"):
		next_pos = agent.get_next_path_position()
	# prefer get_next_location if available or if above returned Vector2.ZERO
	if (next_pos == Vector2.ZERO) and agent.has_method("get_next_location"):
		next_pos = agent.get_next_location()

	# fallback to target_position if we still didn't get a next node
	if next_pos == Vector2.ZERO and agent.target_position != Vector2.ZERO:
		# if we are already close to the target position then stop
		var dist_to_target = global_position.distance_to(agent.target_position)
		if dist_to_target <= agent.target_desired_distance:
			velocity_vec = Vector2.ZERO
			if _debug_enabled:
				print("[Enemy DEBUG] Next_pos fallback is target_position but we're already within desired distance (", dist_to_target, ")")
			return
		# otherwise use target_position so we keep moving toward the moving player
		next_pos = agent.target_position

	# still nothing useful -> stop
	if next_pos == Vector2.ZERO:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			print("[Enemy DEBUG] Could not resolve next_pos from agent; next_pos==Vector2.ZERO, target_position:", agent.target_position)
		return

	# compute direction and velocity
	var dir: Vector2 = (next_pos - global_position)
	var dist = dir.length()
	if dist < 1.0:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			print("[Enemy DEBUG] next_pos too close to move towards (dist:", dist, ")")
		return

	velocity_vec = dir.normalized() * speed

	# debug info
	if _debug_enabled:
		print("[Enemy DEBUG] next_pos:", next_pos, " target:", agent.target_position, " nav_finished:", agent.is_navigation_finished(), " velocity_vec:", velocity_vec)

# ------------------------------
# Detection (multi-ray cone, offset origin)
# ------------------------------
func _scan_for_player(radius: float) -> bool:
	if detection_timer > 0.0:
		return false
	detection_timer = detection_interval

	if player == null:
		return false

	var origin: Vector2 = global_position + eye_offset
	var player_pos: Vector2 = player.global_position
	var to_player: Vector2 = player_pos - origin
	var dist_to_player: float = to_player.length()
	if dist_to_player > radius:
		return false

	var space := get_world_2d().direct_space_state

	var angle_to_player: float = to_player.angle()
	var half_spread: float = deg_to_rad(60.0)
	var ray_count: int = max(detection_rays, 1)

	# COLLISION MASK SETUP -------------------------
	# Layer 1 = Player
	# Layer 5 = Walls
	var mask := (1 << 0) | (1 << 4)
	# ----------------------------------------------

	for i in range(ray_count):
		var t := float(i) / float(max(ray_count - 1, 1))
		var angle = lerp(angle_to_player - half_spread, angle_to_player + half_spread, t)
		var ray_end := origin + Vector2.RIGHT.rotated(angle) * radius

		var query := PhysicsRayQueryParameters2D.create(origin, ray_end)
		query.collide_with_bodies = true
		query.collide_with_areas = true
		query.collision_mask = mask
		query.exclude = [self]  # ignore own collider

		var result := space.intersect_ray(query)

		if result.is_empty():
			continue

		var collider = result.get("collider")

		if collider and collider.is_in_group("Player"):
			if _debug_enabled:
				print("[Enemy DEBUG] Player detected at:", player.global_position)
			return true

	return false

# ------------------------------
# Agent velocity callback
# ------------------------------
func _on_agent_velocity(safe_velocity: Vector2) -> void:
	if state in [CHASE, SEARCH, FLEE]:
		velocity_vec = safe_velocity.limit_length(speed)
	else:
		velocity_vec = Vector2.ZERO

# ------------------------------
# Attack
# ------------------------------
func _perform_attack() -> void:
	if not player:
		_set_state(IDLE)
		return

	if sprite:
		sprite.flip_h = player.global_position.x < global_position.x

	var dmg: int = attack_damage
	if _debug_enabled:
		print("[Enemy DEBUG] Attacking player for", dmg, "damage")
	emit_signal("enemy_hit_player", dmg)
	if player.has_method("apply_damage"):
		player.apply_damage(dmg)

	_apply_knockback_to(player, knockback_strength)

	attack_timer = attack_cooldown
	_set_state(CHASE)

# ------------------------------
# Damage / death
# ------------------------------
func take_damage(amount: int, source_pos: Vector2 = Vector2.ZERO, knockback_mult: float = 1.0) -> void:
	hp -= amount
	if _debug_enabled:
		print("[Enemy] took damage:", amount, "hp now:", hp)
	emit_signal("enemy_damaged", amount)
	if hp <= 0 and state != DEAD:
		_die()
	else:
		_apply_knockback_from(source_pos, knockback_strength * knockback_mult)

func _apply_knockback_from(source_pos: Vector2, strength: float) -> void:
	var dir: Vector2 = (global_position - source_pos)
	if dir.length() == 0:
		dir = Vector2.RIGHT
	velocity_vec = dir.normalized() * strength

func _apply_knockback_to(target: Node, strength: float) -> void:
	if not target:
		return

	var force: Vector2 = (target.global_position - global_position).normalized() * strength

	# Preferred knockback if player implements this
	if target.has_method("external_knockback"):
		target.external_knockback(force)
		return

	# If target is enemy-type CharacterBody2D, not player
	if target is CharacterBody2D:
		# DO NOT override player's velocity – this only applies to NPC-type bodies
		target.velocity = force

func _die() -> void:
	_set_state(DEAD)
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("death"):
		sprite.play("death")
	if _debug_enabled:
		print("[Enemy] playing death animation")
	_spawn_loot()
	emit_signal("enemy_died")
	queue_free()

func _spawn_loot() -> void:
	if loot_table.size() == 0:
		return
	var pick: int = randi() % loot_table.size()
	var item_res = loot_table[pick]
	if world_item_scene:
		var world_item = world_item_scene.instantiate()
		if "item" in world_item:
			world_item.item = item_res
			world_item.quantity = 1
		world_item.global_position = global_position
		get_tree().current_scene.add_child(world_item)
		if _debug_enabled:
			print("[Enemy] spawned loot at", global_position, "item:", item_res)
	else:
		if _debug_enabled:
			print("[Enemy] dropped:", item_res)
