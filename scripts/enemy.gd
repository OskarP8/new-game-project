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
@export var weapon_scene: PackedScene
var weapon: Node = null  # Weapon instance (type: Weapon)

# Nodes (ensure these paths exist in the enemy scene)
@onready var agent: NavigationAgent2D = $Agent
@onready var body_anim: AnimatedSprite2D = $Graphics/Body
@onready var head_anim: AnimatedSprite2D = $Graphics/Head
@onready var weapon_pivot: Node2D = $Graphics/WeaponPivot
# Damage receiver (Area2D) that player weapons hit
@onready var damage_area: Area2D = $Damage

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
var attack_windup: float = 0.5
var attack_recover: float = 0.5
var attack_phase: String = ""   # "", "windup", "attack", "recover"

# sight smoothing / memory (kept minor for losing sight)
var time_since_seen: float = 0.0
var lose_sight_delay: float = 0.8
var facing_left: bool = false
var post_attack_left: bool = false

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

# Play body & head animations if present; head uses same name as body (you said you'll add those)
func _play_anim_if_exists(name: String) -> void:
	if body_anim and body_anim.sprite_frames and body_anim.sprite_frames.has_animation(name):
		body_anim.play(name)
	else:
		if _debug_enabled:
			print("[Enemy] body anim not found:", name)
	# keep head synchronized to body animation if head has it
	if head_anim and head_anim.sprite_frames and head_anim.sprite_frames.has_animation(name):
		head_anim.play(name)
	else:
		# fallback: stop or play idle if available
		if name == "idle":
			if head_anim and head_anim.sprite_frames and head_anim.sprite_frames.has_animation("idle"):
				head_anim.play("idle")
		if _debug_enabled:
			print("[Enemy] head anim not found:", name)

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

	# Agent tuning
	if agent:
		agent.path_desired_distance = 2.0
		agent.target_desired_distance = 2.0
		agent.avoidance_enabled = true
		agent.avoidance_layers = 1
		agent.avoidance_mask = 1
		if agent.radius == 0:
			agent.radius = 8.0

	# connect velocity callback
	if agent:
		var callable := Callable(self, "_on_agent_velocity")
		if agent.velocity_computed.is_connected(callable):
			agent.velocity_computed.disconnect(callable)
		agent.velocity_computed.connect(callable)

	# connect damage receiver (player weapons hit this Area2D)
	if damage_area:
		if not damage_area.is_connected("body_entered", Callable(self, "_on_damage_area_body_entered")):
			damage_area.body_entered.connect(Callable(self, "_on_damage_area_body_entered"))

	_play_anim_if_exists("idle")
	_set_state(IDLE)
	set_physics_process(true)
	if _debug_enabled:
		print("[Enemy] ready — hp:", hp, "player found:", player != null)

	await get_tree().process_frame

	agent.avoidance_enabled = true
	agent.avoidance_layers = 1
	agent.avoidance_mask = 1

	# Instantiate weapon if provided and call initialize(owner)
	if weapon_scene:
		var inst = weapon_scene.instantiate()
		if inst:
			weapon = inst
			weapon_pivot.add_child(weapon)
			weapon.global_position = weapon_pivot.global_position
			weapon.position = Vector2.ZERO

			# call initialize if available, else try to set owner property as fallback
			if weapon.has_method("initialize"):
				weapon.initialize(self)
			else:
				# fallback: set weapon_owner property if exists
				if "weapon_owner" in weapon:
					weapon.weapon_owner = self
			if weapon and weapon.has_method("set_flipped"):
				weapon.set_flipped(facing_left)

	if agent.radius < 1:
		agent.radius = 12

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

	if weapon and weapon.has_method("update_weapon"):
		weapon.update_weapon(delta)

	# apply movement
	velocity = velocity_vec
	move_and_slide()

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
		return

	var seen: bool = _scan_for_player(chase_radius)

	if seen:
		time_since_seen = 0.0
		if agent:
			var map_rid = agent.get_navigation_map()
			if map_rid != RID():
				var safe_target = NavigationServer2D.map_get_closest_point(map_rid, player.global_position)
				agent.target_position = safe_target
				last_seen_pos = safe_target
	else:
		time_since_seen += delta
		if time_since_seen >= lose_sight_delay:
			_set_state(SEARCH)
			search_timer = search_duration
			if agent:
				agent.target_position = last_seen_pos
			if _debug_enabled:
				print("[Enemy DEBUG] Lost sight -> SEARCH. Last seen:", last_seen_pos)
			return

	# Attack check (melee range)
	if global_position.distance_to(player.global_position) <= attack_range and attack_timer <= 0.0:
		_set_state(ATTACK)
		return

	_update_agent_movement()

	# update facing when chasing so visuals follow
	if player:
		facing_left = player.global_position.x < global_position.x
	_update_flip_and_layers()

func _process_search(delta: float) -> void:
	search_timer -= delta
	if _scan_for_player(chase_radius):
		time_since_seen = 0.0
		_set_state(CHASE)
		return

	if agent:
		agent.target_position = last_seen_pos

	_update_agent_movement()

	if agent and agent.is_navigation_finished():
		if search_timer <= 0.0:
			_set_state(IDLE)
		return

func _process_attack_state(delta: float) -> void:
	if attack_phase == "":
		# enter windup phase
		attack_phase = "windup"
		velocity_vec = Vector2.ZERO
		attack_timer = attack_windup
		facing_left = player.global_position.x < global_position.x
		_update_flip_and_layers()
		return

	# W I N D U P
	if attack_phase == "windup":
		attack_timer -= delta
		velocity_vec = Vector2.ZERO
		if attack_timer <= 0:
			attack_phase = "attack"
			_perform_attack()
		return

	# A T T A C K
	if attack_phase == "attack":
		attack_timer = attack_recover
		attack_phase = "recover"
		return

	# R E C O V E R
	if attack_phase == "recover":
		attack_timer -= delta
		velocity_vec = Vector2.ZERO
		if attack_timer <= 0:
			attack_phase = ""
			_set_state(CHASE)
		return

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
# Movement / agent helper
# ------------------------------
func _update_agent_movement() -> void:
	if not agent:
		velocity_vec = Vector2.ZERO
		return

	var next_pos := agent.get_next_path_position()
	if next_pos == Vector2.ZERO:
		velocity_vec = Vector2.ZERO
		return

	var dir := next_pos - global_position
	var dist := dir.length()
	if dist < 1.0:
		velocity_vec = Vector2.ZERO
		return

	agent.set_velocity(dir.normalized() * speed)

# ------------------------------
# Detection (multi-ray cone)
# ------------------------------
func _scan_for_player(radius: float) -> bool:
	if detection_timer > 0.0:
		return false
	detection_timer = detection_interval

	if player == null:
		return false

	var origin: Vector2 = global_position + eye_offset
	var to_player = player.global_position - origin
	if to_player.length() > radius:
		return false

	var angle_center = to_player.angle()
	var half_spread := deg_to_rad(60)
	var ray_count = max(detection_rays, 1)

	var space := get_world_2d().direct_space_state
	var mask := (1 << 0) | (1 << 4)  # PLAYER + OBSTACLE (adjust bits if needed)

	var saw_player := false

	for i in range(ray_count):
		var t := float(i) / float(max(ray_count - 1, 1))
		var angle = lerp(angle_center - half_spread, angle_center + half_spread, t)

		var ray_end := origin + Vector2.RIGHT.rotated(angle) * radius
		var query := PhysicsRayQueryParameters2D.create(origin, ray_end)
		query.collide_with_bodies = true
		query.collide_with_areas = true
		query.collision_mask = mask
		query.exclude = [self]

		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue

		var collider = hit.get("collider")
		if not collider:
			continue

		if collider.is_in_group("Player"):
			saw_player = true
		else:
			if _debug_enabled:
				if Time.get_ticks_msec() % 2000 < 50:
					print("[Enemy DEBUG] LOS blocked by:", str(collider), "at", hit.get("position"))

	return saw_player

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

	# start weapon attack if we have one
	if weapon and weapon.has_method("start_attack"):
		weapon.start_attack()

	# flip visuals toward player
	facing_left = player.global_position.x < global_position.x
	_update_flip_and_layers()

	# emit signal for external listeners
	var dmg: int = attack_damage
	emit_signal("enemy_hit_player", dmg)

	# don't apply damage here — weapon hitbox will call back when it hits the player
	# apply knockback only when weapon hits via weapon_notify_hit

	attack_timer = attack_cooldown

# Called by Weapon when it successfully hits a body (Weapon calls weapon_owner.weapon_notify_hit(body))
func weapon_notify_hit(body: Node) -> void:
	if not body:
		return
	# Only consider Player hits
	if not body.is_in_group("Player"):
		return

	# Apply damage via player's method if it exists
	if body.has_method("apply_damage"):
		body.apply_damage(attack_damage)
	# Apply knockback to player if they have external_knockback
	if body.has_method("external_knockback"):
		var force = (body.global_position - global_position).normalized() * knockback_strength
		body.external_knockback(force)

# ------------------------------
# Damage / death (enemy receives damage from player weapons/hits)
# ------------------------------
func take_damage(amount: int, source_pos: Vector2 = Vector2.ZERO, knockback_mult: float = 1.0) -> void:
	hp -= amount
	if _debug_enabled:
		print("[Enemy] took damage:", amount, "hp now:", hp)
	emit_signal("enemy_damaged", amount)
	# play hit anim on head/body if present
	if body_anim and body_anim.sprite_frames and body_anim.sprite_frames.has_animation("hit"):
		body_anim.play("hit")
	if head_anim and head_anim.sprite_frames and head_anim.sprite_frames.has_animation("hit"):
		head_anim.play("hit")

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
	if target.has_method("external_knockback"):
		target.external_knockback(force)
		return
	if target is CharacterBody2D:
		target.velocity = force

func _die() -> void:
	_set_state(DEAD)
	if body_anim and body_anim.sprite_frames and body_anim.sprite_frames.has_animation("death"):
		body_anim.play("death")
	if head_anim and head_anim.sprite_frames and head_anim.sprite_frames.has_animation("death"):
		head_anim.play("death")
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

# ------------------------------
# Damage area callback (player weapons will collide with this area)
# ------------------------------
func _on_damage_area_body_entered(body: Node) -> void:
	# This is called when a player's attack hitbox collides with the enemy's Damage Area2D.
	# The player's weapon should call apply_damage on this node (or call enemy.take_damage)
	# If the player's weapon system instead relies on signals, handle that in the player's weapon script.
	# Nothing is forced here; this handler is present so you can hook/respond if needed.
	# Example: if the hitting body has a property "damage" we can apply it:
	if not body:
		return
	# optional: player weapon may be an Area2D or Node2D with 'damage' property
	if "damage" in body:
		var dmg = int(body.damage)
		take_damage(dmg, body.global_position)
	# otherwise player script should call enemy.take_damage directly.

# ------------------------------
# Util: Update flips and layer ordering (body/weapon/head)
# ------------------------------
func _update_flip_and_layers() -> void:
	# Flip visuals
	if body_anim:
		body_anim.flip_h = facing_left
	if head_anim:
		head_anim.flip_h = facing_left

	# Layering (relative within this enemy)
	# Default order: body (0) -> weapon (1) -> head (2)
	var weapon_node = null
	if weapon_pivot:
		weapon_node = weapon_pivot
	if weapon_node:
		body_anim.z_index = 0
		weapon_node.z_index = 1
		if head_anim:
			head_anim.z_index = 2

# ------------------------------
# Misc helpers
# ------------------------------
func _find_reachable_near(center: Vector2, tries: int = 8, radius: float = 16.0) -> Vector2:
	if not agent:
		return Vector2.ZERO
	var map_rid = agent.get_navigation_map()
	if map_rid == RID():
		return Vector2.ZERO

	var rng = RandomNumberGenerator.new()
	rng.randomize()
	for i in range(tries):
		var a = rng.randf_range(0.0, TAU)
		var r = rng.randf_range(0.0, radius)
		var sample = center + Vector2.RIGHT.rotated(a) * r
		var clamped = NavigationServer2D.map_get_closest_point(map_rid, sample)
		if clamped != Vector2.ZERO:
			if clamped.distance_to(global_position) < center.distance_to(global_position):
				return clamped
	return Vector2.ZERO
