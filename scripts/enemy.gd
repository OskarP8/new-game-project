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
var lose_sight_delay: float = 0.3
var frames_seen: int = 0
var frames_not_seen: int = 0
var frames_required: int = 2

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

	# Find player by group (robust)
	var players: Array = get_tree().get_nodes_in_group("Player")
	if players.size() > 0:
		player = players[0]
	else:
		player = null

	# nav agent hookup (safe)
	if agent:
		var callable := Callable(self, "_on_agent_velocity")
		if agent.velocity_computed.is_connected(callable):
			agent.velocity_computed.disconnect(callable)
		agent.velocity_computed.connect(callable)
		agent.target_desired_distance = 4.0

	# start
	_play_anim_if_exists("idle")
	_set_state(IDLE)
	set_physics_process(true)
	if _debug_enabled:
		print("[Enemy] ready — hp:", hp, "player found:", player != null)

# ------------------------------
# Physics loop
# ------------------------------
func _physics_process(delta: float) -> void:
	detection_timer = max(0.0, detection_timer - delta)
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

func _process_chase(delta: float) -> void:
	if not player:
		_set_state(IDLE)
		if _debug_enabled:
			print("[Enemy DEBUG] Giving up search, returning to IDLE")
		return

	var seen: bool = _scan_for_player(chase_radius)
	if seen:
		frames_seen += 1
		frames_not_seen = 0
	else:
		frames_seen = 0
		frames_not_seen += 1

	if frames_seen >= frames_required:
		last_seen_pos = player.global_position
		if agent:
			agent.target_position = last_seen_pos
		time_since_seen = 0.0
	else:
		time_since_seen += delta
		if frames_not_seen >= frames_required or time_since_seen >= lose_sight_delay:
			_set_state(SEARCH)
			if _debug_enabled:
				print("[Enemy DEBUG] Lost sight of player, switching to SEARCH. Last seen:", last_seen_pos)
			search_timer = search_duration
			if agent:
				agent.target_position = last_seen_pos
			return

	var dist_to_player: float = global_position.distance_to(player.global_position)
	if dist_to_player <= attack_range and attack_timer <= 0.0:
		_set_state(ATTACK)
		return

	_update_agent_movement()
	if _debug_enabled:
		print("[Enemy DEBUG] Following player -> target_position:", agent.target_position)


func _process_search(delta: float) -> void:
	search_timer -= delta
	if _scan_for_player(chase_radius):
		_set_state(CHASE)
		return

	_update_agent_movement()

	if search_timer <= 0.0:
		_set_state(IDLE)
		if agent:
			agent.target_position = global_position

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
func _update_agent_movement() -> void:
	# no agent -> no movement
	if not agent:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			print("[Enemy DEBUG] No agent present")
		return

	# if navigation finished -> stop
	if agent.is_navigation_finished():
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			print("[Enemy DEBUG] Agent navigation finished; at target")
		return

	# Try a couple of ways to get a sensible "next position"
	var next_pos: Vector2 = Vector2.ZERO

	# 1) preferred: get_next_path_position (if available)
	if agent.has_method("get_next_path_position"):
		next_pos = agent.get_next_path_position()

	# 2) fallback: get_next_location (older/newer API differences)
	if next_pos == Vector2.ZERO and agent.has_method("get_next_location"):
		next_pos = agent.get_next_location()

	# 3) fallback: if agent has a target_position, use that as last resort
	if next_pos == Vector2.ZERO and agent.target_position != Vector2.ZERO:
		# if we're already very close to target_position, treat as finished
		if global_position.distance_to(agent.target_position) <= agent.target_desired_distance:
			velocity_vec = Vector2.ZERO
			if _debug_enabled:
				print("[Enemy DEBUG] Next_pos fallback is target_position but we're already at target; stopping")
			return
		next_pos = agent.target_position

	# 4) still nothing: give up
	if next_pos == Vector2.ZERO:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			print("[Enemy DEBUG] Could not resolve next_pos from agent; next_pos==Vector2.ZERO, target_position:", agent.target_position)
		return

	# compute direction and velocity
	var dir: Vector2 = (next_pos - global_position)
	if dir.length() < 1.0:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			print("[Enemy DEBUG] next_pos too close to move towards (dist:", dir.length(), ")")
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

	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state

	var angle_to_player: float = to_player.angle()
	var half_spread: float = deg_to_rad(30.0)
	var ray_count: int = max(detection_rays, 1)

	for i: int in range(ray_count):
		var t: float = float(i) / float(max(ray_count - 1, 1))
		var angle: float = lerp(angle_to_player - half_spread, angle_to_player + half_spread, t)
		var ray_end: Vector2 = origin + Vector2.RIGHT.rotated(angle) * radius

		var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(origin, ray_end)
		var exclude_list: Array = [self]
		for child in get_children():
			if child is CollisionShape2D or child is CollisionObject2D:
				exclude_list.append(child)
		query.exclude = exclude_list
		query.collide_with_bodies = true
		query.collide_with_areas = true

		var res: Dictionary = space.intersect_ray(query)
		if res.is_empty():
			continue

		var collider_obj: Object = res.get("collider", null)
		if collider_obj == null:
			continue
		var collider_node: Node = collider_obj as Node
		if collider_node and collider_node.is_in_group("Player"):
			if _debug_enabled:
				print("[Enemy DEBUG] Player detected at:", player.global_position, " by enemy at:", global_position)
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
