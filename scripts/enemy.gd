extends CharacterBody2D
class_name Enemy

# --- Stats ---
@export var max_hp: int = 10
@export var speed: float = 60.0
@export var notice_radius: float = 120.0
@export var chase_radius: float = 220.0
@export var attack_range: float = 24.0
@export var attack_damage: int = 10
@export var attack_cooldown: float = 3.0
@export var detection_rays: int = 16
@export var detection_interval: float = 0.12
@export var corpse_lifetime: float = 20.0
@export var fade_duration: float = 2.0
var _loot_dropped: bool = false

var is_dead: bool = false

# Scenes/resources
@export var loot_table: Array[LootDrop] = []
@export var world_item_scene: PackedScene = preload("res://scenes/world_item.tscn")
@export var weapon_scene: PackedScene
var weapon: Node = null

# Nodes (ensure paths exist)
@onready var agent: NavigationAgent2D = $Agent
@onready var body_anim: AnimatedSprite2D = $Graphics/Body
@onready var head_anim: AnimatedSprite2D = $Graphics/Head
@onready var weapon_pivot: Node2D = $Graphics/WeaponPivot
@onready var damage_area: Area2D = $Damage if has_node("Damage") else null
@onready var anim_player: AnimationPlayer = $Graphics/AnimationPlayer

# State enum
enum { IDLE, ALERT, CHASE, SEARCH, ATTACK, FLEE, DEAD }
var state: int = IDLE
var hp: int
var player: Node = null
var last_seen_pos: Vector2 = Vector2.ZERO

var _circling_active: bool = false  # NEW: true while we are circling during a cooldown
var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_time: float = 0.0

# timers/motion
var detection_timer: float = 0.0
var attack_timer: float = 0.0
var search_timer: float = 0.0
var search_duration: float = 2.0
var velocity_vec: Vector2 = Vector2.ZERO

# attack timing
var attack_windup_time: float = 0.5
var attack_recovery_time: float = 0.5
var attack_active: bool = false

# circling
var _circle_dir: int = 1
var _circle_radius_mult: float = 1.3
var _circle_cache: Vector2 = Vector2.ZERO
var _circle_cache_ttl: float = 0.0
var _circle_cache_refresh: float = 0.25  # seconds between recalcs

# sight smoothing / memory
var time_since_seen: float = 0.0
var lose_sight_delay: float = 0.8
var facing_left: bool = false
var post_attack_left: bool = false

@export var eye_offset: Vector2 = Vector2(0, -8)

signal enemy_hit_player(damage)
signal enemy_damaged(amount)
signal enemy_died(enemy)

var _debug_enabled: bool = true

# ------------------------------
func _set_state(new_state: int) -> void:
	if is_dead and new_state != DEAD:
		return
	if state == new_state:
		return
	var old_state: int = state
	state = new_state
	if _debug_enabled:
		print("[Enemy] state:", old_state, "->", new_state, " pos:", global_position)

	# play normal animations for transitions, but DO NOT auto-play "attack" here
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
			# intentionally do NOT auto-play "attack" here — the actual attack anim must start
			# when the windup completes and _perform_attack() runs (so windup delay is respected).
			pass
		FLEE:
			_play_anim_if_exists("flee")
		DEAD:
			_play_anim_if_exists("death")

func _play_anim_if_exists(name: String) -> void:
	if body_anim and body_anim.sprite_frames and body_anim.sprite_frames.has_animation(name):
		body_anim.play(name)
		if _debug_enabled:
			print("[Enemy] playing anim:", name)
	else:
		if _debug_enabled:
			print("[Enemy] body anim not found:", name)
	if head_anim and head_anim.sprite_frames and head_anim.sprite_frames.has_animation(name):
		head_anim.play(name)

# ------------------------------
func _ready() -> void:
	hp = max_hp
	var players: Array = get_tree().get_nodes_in_group("Player")
	player = players[0] if players.size() > 0 else null

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

	# connect damage area
	if damage_area:
		if not damage_area.is_connected("body_entered", Callable(self, "_on_damage_area_body_entered")):
			damage_area.body_entered.connect(Callable(self, "_on_damage_area_body_entered"))

	_play_anim_if_exists("idle")
	_set_state(IDLE)
	set_physics_process(true)
	if _debug_enabled:
		print("[Enemy] ready — hp:", hp, "player found:", player != null)

	await get_tree().process_frame

	# instantiate weapon and initialize
	if weapon_scene:
		var inst = weapon_scene.instantiate()
		if inst:
			weapon = inst
			add_child(weapon) # will reparent itself
			if weapon.has_method("initialize"):
				weapon.initialize(self)
				if weapon.has_method("equip_for_owner"):
					weapon.equip_for_owner("enemy")
				if weapon.has_method("update_weapon"):
					weapon.update_weapon(0.0)

	# initial facing
	if player:
		facing_left = player.global_position.x < global_position.x
	_update_flip_and_layers()

	if agent.radius < 1:
		agent.radius = 12

# ------------------------------
func _physics_process(delta: float) -> void:
	if is_dead:
		if knockback_time > 0.0:
			knockback_time -= delta
			velocity = knockback_velocity
			if agent:
				agent.set_velocity(Vector2.ZERO)
			move_and_slide()
		else:
			# knockback finished → drop loot once
			if not _loot_dropped:
				_loot_dropped = true
				_spawn_loot_with_arc()
		return  # ⛔ stop ALL other logic

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

	if knockback_time > 0.0:
		knockback_time -= delta
		velocity = knockback_velocity
		if agent:
			agent.set_velocity(Vector2.ZERO)

		move_and_slide()
		return  # ⛔ ABSOLUTELY NOTHING ELSE THIS FRAME

	else:
		velocity = velocity_vec

	move_and_slide()

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

	# Attack check
	if global_position.distance_to(player.global_position) <= attack_range and attack_timer <= 0.0:
		_set_state(ATTACK)
		return

	# Circling behavior while on cooldown
	if attack_timer > 0.0:
		var dist_to_player = global_position.distance_to(player.global_position)

		# Circle only when close enough to the player
		if dist_to_player <= attack_range * 1.5:
			# start circling (choose direction once per circling episode)
			if not _circling_active:
				_circling_active = true
				# pick a random direction and stick with it for this episode
				_circle_dir = 1 if randi() % 2 == 0 else -1
				if _debug_enabled:
					print("[Enemy DEBUG] start circling, dir:", _circle_dir)

			var circle_target = _get_circling_target()

			if circle_target != Vector2.ZERO and agent:
				agent.target_position = circle_target
				# force a movement update so agent computes velocity this frame
				_update_agent_movement()

				if _debug_enabled:
					print("[Enemy DEBUG] Circling -> target:", circle_target, " next:", agent.get_next_path_position())

			# Update facing while circling
			if player:
				facing_left = player.global_position.x < global_position.x
			_update_flip_and_layers()

			# don't fall back to normal chase
			return
	else:
		# cooldown finished — stop circling
		if _circling_active:
			_circling_active = false
			if _debug_enabled:
				print("[Enemy DEBUG] stop circling (cooldown ended)")

	# Normal chase
	_update_agent_movement()
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
	# Start windup then attack
	if attack_timer <= 0.0 and not attack_active:
		attack_active = true
		velocity_vec = Vector2.ZERO
		if agent:
			agent.set_velocity(Vector2.ZERO)
		if player:
			facing_left = player.global_position.x < global_position.x
		_update_flip_and_layers()
		# perform windup wait — only after this will we actually play attack animations
		await get_tree().create_timer(attack_windup_time).timeout
		# perform attack: play attack anim then weapon start
		_perform_attack()
		# recovery
		await get_tree().create_timer(attack_recovery_time).timeout
		attack_active = false
		_set_state(CHASE)

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
func _get_circling_target() -> Vector2:
	if not player or not agent:
		return Vector2.ZERO

	_circle_cache_ttl -= get_physics_process_delta_time()
	if _circle_cache_ttl > 0.0:
		return _circle_cache

	_circle_cache_ttl = _circle_cache_refresh

	var map_rid = agent.get_navigation_map()
	if map_rid == RID():
		return Vector2.ZERO

	var r = max(attack_range * _circle_radius_mult, attack_range + 12.0)
	var to_player = player.global_position - global_position
	if to_player.length() == 0:
		to_player = Vector2.RIGHT

	var base_angle = to_player.angle()
	var target_angle = base_angle + (PI / 2.0) * float(_circle_dir)

	var sample = player.global_position + Vector2.RIGHT.rotated(target_angle) * r
	_circle_cache = NavigationServer2D.map_get_closest_point(map_rid, sample)

	return _circle_cache

func _compute_circling_point() -> Vector2:
	if not player or not agent:
		return Vector2.ZERO
	var map_rid = agent.get_navigation_map()
	if map_rid == RID():
		return Vector2.ZERO
	var r = max(attack_range * _circle_radius_mult, attack_range + 8.0)
	var to_player = player.global_position - global_position
	if to_player.length() == 0:
		to_player = Vector2.RIGHT
	var base_angle = to_player.angle()
	_circle_dir = -_circle_dir if randi() % 3 == 0 else _circle_dir
	var target_angle = base_angle + (PI / 2.0) * float(_circle_dir)
	var sample = player.global_position + Vector2.RIGHT.rotated(target_angle) * r
	var clamped = NavigationServer2D.map_get_closest_point(map_rid, sample)
	if clamped == Vector2.ZERO:
		sample = player.global_position + Vector2.RIGHT.rotated(base_angle - (PI / 2.0) * float(_circle_dir)) * r
		clamped = NavigationServer2D.map_get_closest_point(map_rid, sample)
	return clamped

# ------------------------------
func _scan_for_player(radius: float) -> bool:
	if player == null:
		return false

	var origin := global_position
	var to_player = player.global_position - origin

	if to_player.length() > radius:
		return false

	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(
		origin,
		player.global_position
	)

	query.collision_mask = (1 << 0) | (1 << 4) # player + walls
	query.exclude = [self.get_rid()]

	var hit := space.intersect_ray(query)

	if hit.is_empty():
		return false

	return hit.collider.is_in_group("Player")

# ------------------------------
func _on_agent_velocity(safe_velocity: Vector2) -> void:
	if knockback_time > 0.0:
		return  # 🔒 do NOT override knockback

	if state in [CHASE, SEARCH, FLEE]:
		velocity_vec = safe_velocity.limit_length(speed)
	else:
		velocity_vec = Vector2.ZERO

# ------------------------------
func _perform_attack() -> void:
	if is_dead:
		return

	if not player:
		_set_state(IDLE)
		return

	# play enemy body/head attack animation (we only start it here so windup actually delays it)
	_play_anim_if_exists("attack")

	# start weapon attack if present
	if is_instance_valid(weapon) and weapon.has_method("start_attack"):
		weapon.start_attack()

	# flip visuals toward player
	facing_left = player.global_position.x < global_position.x
	_update_flip_and_layers()

	# debug / external signal
	var dmg: int = attack_damage
	emit_signal("enemy_hit_player", dmg)

	# set cooldown
	attack_timer = attack_cooldown

# Called by weapon when it hits a body (weapon calls weapon_owner.weapon_notify_hit(body))
func weapon_notify_hit(body: Node) -> void:
	if not body:
		return
	if not body.is_in_group("Player"):
		return
	if body.has_method("apply_damage"):
		body.apply_damage(attack_damage)
	if body.has_method("external_knockback"):
		var force = (body.global_position - global_position).normalized() * weapon.knockback_strength
		body.external_knockback(force)

	if _debug_enabled:
		print("[Enemy] weapon_notify_hit -> applied", attack_damage, "to", body)

# ------------------------------
func take_damage(amount: int, source_pos: Vector2, knockback_velocity_strength: float) -> void:
	if is_dead:
		return  # cannot hit dead enemies
	hp -= amount
	if _debug_enabled:
		print("[Enemy] took damage:", amount, "hp now:", hp)
	emit_signal("enemy_damaged", amount)

	if body_anim and body_anim.sprite_frames and body_anim.sprite_frames.has_animation("hit"):
		body_anim.play("hit")
	if head_anim and head_anim.sprite_frames and head_anim.sprite_frames.has_animation("hit"):
		head_anim.play("hit")
	if hp <= 0 and not is_dead:
		_apply_knockback_from(source_pos, knockback_velocity_strength)
		_die()
	else:
		_apply_knockback_from(source_pos, knockback_velocity_strength)


func _apply_knockback_from(source_pos: Vector2, strength: float) -> void:
	var dir = global_position - source_pos
	if dir.length() == 0:
		dir = Vector2.RIGHT

	var knockback_duration := 0.25
	var velocity_mag := strength / knockback_duration

	if _debug_enabled:
		print(
			"[Enemy KB APPLY]",
			"strength =", strength,
			"duration =", knockback_duration,
			"velocity magnitude =", velocity_mag
		)

	knockback_velocity = dir.normalized() * velocity_mag
	knockback_time = knockback_duration

func _die() -> void:
	if is_dead:
		return

	is_dead = true
	_set_state(DEAD)

	# stop AI / navigation
	if agent:
		agent.set_velocity(Vector2.ZERO)
		agent.avoidance_enabled = false

	# disable weapon + damage
	if weapon:
		weapon.queue_free()
		weapon = null
	if damage_area:
		damage_area.monitoring = false
		damage_area.set_deferred("collision_layer", 0)
		damage_area.set_deferred("collision_mask", 0)
	# hard stop all normal movement
	velocity_vec = Vector2.ZERO
	velocity = Vector2.ZERO

	# play death animation (AnimationPlayer)
	if anim_player and anim_player.has_animation("death"):
		anim_player.play("death")

	if _debug_enabled:
		print("[Enemy] died — entering corpse state")

	emit_signal("enemy_died", self)
	_handle_corpse_lifecycle()

func _spawn_loot_with_arc() -> void:
	if loot_table.is_empty():
		return

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	for drop: LootDrop in loot_table:
		if drop == null or drop.item == null:
			continue
		if rng.randf() > drop.chance:
			continue

		var world_item: WorldItem = world_item_scene.instantiate()
		world_item.item = drop.item
		world_item.quantity = 1
		get_tree().current_scene.add_child(world_item)

		# start at enemy position
		world_item.global_position = global_position

		# random throw direction
		var dir := Vector2(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.2, -0.4)
		).normalized()

		var distance := rng.randf_range(24.0, 48.0)
		var target_pos := global_position + dir * distance

		# ARC animation using tween
		var tween := world_item.create_tween()
		tween.set_trans(Tween.TRANS_QUAD)
		tween.set_ease(Tween.EASE_OUT)

		# vertical arc (up then down)
		tween.tween_property(
			world_item,
			"global_position",
			target_pos,
			0.45
		)

		# optional spin for juice
		if world_item.has_node("Sprite2D"):
			tween.parallel().tween_property(
				world_item.get_node("Sprite2D"),
				"rotation",
				rng.randf_range(-PI, PI),
				0.45
			)

		if _debug_enabled:
			print("[Loot] Thrown:", drop.item.name)

func _on_damage_area_body_entered(body: Node) -> void:
	if not body:
		return
	if "damage" in body:
		var dmg = int(body.damage)
		# environmental / generic damage → very small knockback
		take_damage(dmg, body.global_position, 40.0)

func _update_flip_and_layers() -> void:
	if body_anim:
		body_anim.flip_h = facing_left
	if head_anim:
		head_anim.flip_h = facing_left
	if weapon_pivot:
		body_anim.z_index = 0
		weapon_pivot.z_index = 1
		if head_anim:
			head_anim.z_index = 2

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

func _process_flee(delta):
	pass
func _apply_knockback_velocity(source_pos: Vector2, strength: float) -> void:
	var dir := global_position - source_pos
	if dir.length() == 0:
		dir = Vector2.RIGHT

	knockback_velocity = dir.normalized() * strength
	knockback_time = 0.18  # short, punchy

	if _debug_enabled:
		print(
			"[Enemy KB VELOCITY]",
			"strength =", strength,
			"velocity =", knockback_velocity
		)
func get_attack_damage() -> int:
	return attack_damage

func _handle_corpse_lifecycle() -> void:
	# wait for death animation to finish
	if anim_player:
		await anim_player.animation_finished

	# freeze on last frame
	if anim_player:
		anim_player.stop()

	# wait before fade
	await get_tree().create_timer(corpse_lifetime).timeout

	# fade out
	await _fade_out()

	queue_free()

func _fade_out() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, fade_duration)
	await tween.finished
