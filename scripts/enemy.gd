extends CharacterBody2D
class_name Enemy

# --- Stats ---
@export var max_hp: int = 10
@export var speed: float = 60.0
@export var notice_radius: float = 120.0
@export var chase_radius: float = 220.0
@export var attack_range: float = 24.0
@export var enemy_damage: int = 10
@export var attack_cooldown: float = 3.0
@export var detection_rays: int = 16
@export var detection_interval: float = 0.12
@export var corpse_lifetime: float = 20.0
@export var fade_duration: float = 2.0
var _loot_dropped: bool = false

var is_dead: bool = false
var attack_can_hit := false
var death_anim_locked := false
var ai_disabled := false

# Scenes/resources
@export var loot_table: Array[LootDrop] = []
@export var world_item_scene: PackedScene = preload("res://scenes/world_item.tscn")
@export var weapon_scene: PackedScene
var weapon: Node = null

# ---- Local obstacle-avoidance tuning (replace the prior block) ----
@export var obstacle_avoidance_enabled: bool = true
@export var obstacle_avoidance_strength: float = 10.0   # peak strength when deeply inside obstacle
@export var obstacle_avoidance_padding: float = 0.0      # UNUSED in new logic (kept for compatibility)
@export var obstacle_refresh_interval: float = 2.0       # seconds to refresh cache of obstacles
@export var obstacle_desired_clearance: float = 0.0      # pixels beyond obstacle radius the enemy should avoid (0 => no extra gap)
@export var obstacle_avoidance_min_strength: float = 1.0 # minimum push when just inside (small to avoid sudden large shove)

# NEW: influence radius settings (how far from an obstacle repulsion starts)
@export var obstacle_influence_multiplier: float = 2.5  # influence radius = obstacle_radius * multiplier
@export var obstacle_influence_min: float = 8.0          # minimum extra influence beyond obstacle radius

# ---- internal cache ----
var _nav_obstacles: Array = []
var _obstacle_refresh_timer: float = 0.0

# Nodes (ensure paths exist)
@onready var agent: NavigationAgent2D = $Agent
@onready var body_anim: AnimatedSprite2D = $Graphics/Body
@onready var head_anim: AnimatedSprite2D = $Graphics/Head
@onready var weapon_pivot: Node2D = $Graphics/WeaponPivot
@onready var damage_area: Area2D = $Damage if has_node("Damage") else null
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@export var attack_step_in_distance := 8.0

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
var vert_dir := "down"   # "up" or "down"
@onready var weapon_pivot_back := $Graphics/WeaponPivotBack/WeaponPivot
@onready var weapon_pivot_front := $Graphics/WeaponPivotFront/WeaponPivot

var weapon_holder: Node2D = null

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
	if death_anim_locked:
		return

	if body_anim and body_anim.sprite_frames and body_anim.sprite_frames.has_animation(name):
		body_anim.play(name)

	if head_anim and head_anim.sprite_frames and head_anim.sprite_frames.has_animation(name):
		head_anim.play(name)

# ------------------------------
func _ready() -> void:
	hp = max_hp
	var players: Array = get_tree().get_nodes_in_group("Player")
	player = players[0] if players.size() > 0 else null
	weapon_pivot = weapon_pivot_front
	weapon_holder = weapon_pivot.get_node("WeaponHolder")

	# Agent tuning
	if agent:
		agent.avoidance_enabled = true
		agent.avoidance_layers = 1
		agent.avoidance_mask = 1

	# connect velocity callback
	if agent:
		var callable := Callable(self, "_on_agent_velocity")
		if agent.velocity_computed.is_connected(callable):
			agent.velocity_computed.disconnect(callable)
		agent.velocity_computed.connect(callable)

	# in _ready() after agent exists
	await get_tree().process_frame
	if agent:
		print("Agent navigation map RID:", agent.get_navigation_map())

	# in _process(delta)
	if agent and agent.target_position != Vector2.ZERO:
		var path := agent.get_current_navigation_path()
		print("Agent path length:", path.size())
		if path.size() > 0:
			print("path sample:", path[0], path[min(path.size()-1, 3)])

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

	if weapon_scene and weapon_pivot:
		var inst = weapon_scene.instantiate()
		if inst:
			weapon = inst
			weapon_holder = weapon_pivot.get_node("WeaponHolder")
			weapon_holder.add_child(weapon)

			weapon.initialize(
				self,
				weapon_pivot,
				weapon_holder
			)

			# 🔧 ALIGN WEAPON USING GRIP
			if weapon.has_node("Grip"):
				var grip := weapon.get_node("Grip") as Node2D
				weapon.position = -grip.position
			else:
				weapon.position = Vector2.ZERO

			if weapon.has_method("equip_for_owner"):
				weapon.equip_for_owner("enemy")

			if weapon.has_method("update_weapon"):
				weapon.update_weapon(0.0)

	# initial facing
	if player:
		facing_left = player.global_position.x < global_position.x
	_update_flip_and_layers()

func _process(delta):
	update_weapon_layer()

# ------------------------------
func _physics_process(delta: float) -> void:
	if ai_disabled:
		# allow animations to run, but NO logic
		velocity = Vector2.ZERO
		move_and_slide()
		return

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
		return
	else:
		# 🔁 knockback just ended → reassert movement anim
		if not is_dead and state == CHASE:
			_play_anim_if_exists("walk")

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

	var dist := global_position.distance_to(player.global_position)

	if dist <= attack_range and attack_timer <= 0.0:
		# step in slightly to avoid whiffing
		var dir = (player.global_position - global_position).normalized()
		velocity_vec = dir * speed
		move_and_slide()

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

# call this during _ready() after the scene exists (add this line in your _ready if not present)
#	_collect_nav_obstacles()
# and keep the rest of your existing _ready flow

func _collect_nav_obstacles() -> void:
	_nav_obstacles.clear()
	var root = get_tree().current_scene if get_tree().current_scene else get_tree().get_root()
	var stack := [root]
	while stack.size() > 0:
		var n = stack.pop_back()
		if n is NavigationObstacle2D:
			_nav_obstacles.append(n)
		for i in range(n.get_child_count()):
			stack.append(n.get_child(i))

func _get_obstacle_radius_and_worldpos(obs: NavigationObstacle2D) -> Dictionary:
	# returns {pos: Vector2, radius: float}
	# - prefer an actual CollisionShape2D child (use child global_position + scaled extents)
	# - if none found, fallback to radius = 0 (no accidental avoidance)
	var out := {"pos": obs.global_position, "radius": 0.0}
	var found_shape := false

	for i in range(obs.get_child_count()):
		var ch = obs.get_child(i)
		if not (ch is CollisionShape2D):
			continue
		var shape = ch.shape
		# child global position is authoritative for the collision world pos
		var child_world_pos = ch.global_position
		# Circle shape -> direct radius
		if shape is CircleShape2D:
			var gsx := 1.0
			if "global_scale" in ch:
				gsx = ch.global_scale.x
			out.pos = child_world_pos
			out.radius = float(shape.radius) * gsx
			found_shape = true
			break
		# Rectangle shape -> use half-diagonal as circular approx
		elif shape is RectangleShape2D:
			var gsx := 1.0
			var gsy := 1.0
			if "global_scale" in ch:
				gsx = ch.global_scale.x
				gsy = ch.global_scale.y
			var ext := Vector2(shape.extents.x * gsx, shape.extents.y * gsy)
			out.pos = child_world_pos
			out.radius = ext.length() # half-diagonal -> circular approx
			found_shape = true
			break
		# (add other shapes if you want)

	# If no CollisionShape2D child, return radius 0 (do not assume agent radius)
	if not found_shape:
		out.pos = obs.global_position
		out.radius = 0.0

	return out

func _on_agent_velocity(safe_velocity: Vector2) -> void:
	# don't override knockback
	if knockback_time > 0.0:
		return

	# refresh obstacle cache periodically
	_obstacle_refresh_timer -= get_physics_process_delta_time()
	if _obstacle_refresh_timer <= 0.0:
		_obstacle_refresh_timer = obstacle_refresh_interval
		_collect_nav_obstacles()

	# base velocity from agent
	var final_vel := safe_velocity

	# compute repulsion
	var rep := Vector2.ZERO
	# track nearest for debug
	var nearest_info = null
	var nearest_dist := 1e9

	for obs in _nav_obstacles:
		if not is_instance_valid(obs):
			continue
		var info = _get_obstacle_radius_and_worldpos(obs)
		var obs_pos: Vector2 = info.pos
		var obs_radius: float = float(info.radius)
		var to_enemy := global_position - obs_pos
		var dist := to_enemy.length()
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_info = {"pos": obs_pos, "radius": obs_radius, "node": obs}

		# INFLUENCE radius used for steering (separate from the "cannot enter" nav radius)
		var influence_radius = max(obs_radius * obstacle_influence_multiplier, obs_radius + obstacle_influence_min)

		# if we're outside the influence radius, skip
		if dist >= influence_radius:
			continue

		# penetration relative to the influence boundary
		var penetration = influence_radius - dist
		if dist <= 0.0001:
			# overlapping exactly
			rep += Vector2(randf() - 0.5, randf() - 0.5).normalized() * obstacle_avoidance_strength
			continue

		# outward direction
		var dir_out := (to_enemy / dist).normalized()

		# compute how strong the push should be (0..1) depending where inside influence we are
		# scale so near the real obstacle radius produces stronger push than outer influence band
		var strength_factor := 1.0
		if obs_radius > 0.0:
			# if we're outside actual obstacle_radius but inside influence_radius, ramp from 0..1
			if dist > obs_radius:
				var denom = max(0.0001, influence_radius - obs_radius)
				strength_factor = clamp(1.0 - ((dist - obs_radius) / denom), 0.0, 1.0)
			else:
				# inside the actual obstacle radius -> full factor
				strength_factor = 1.0
		else:
			# zero-radius obstacle -> treat the full influence as ramp to full factor
			var denom = max(0.0001, influence_radius)
			strength_factor = clamp(1.0 - ((dist) / denom), 0.0, 1.0)

		# gain + min strength logic like before, but now scaled by strength_factor
		var gain := obstacle_avoidance_strength * 0.5
		var mag = max(obstacle_avoidance_min_strength, gain * strength_factor)

		# convert penetration -> velocity-like push (smaller when closer to outer edge)
		var push = dir_out * (mag * (penetration / max(influence_radius, 1.0)))

		rep += push

	if rep != Vector2.ZERO:
		final_vel += rep
		if final_vel.length() > 0:
			final_vel = final_vel.normalized() * min(final_vel.length(), speed)

	if state in [CHASE, SEARCH, FLEE]:
		velocity_vec = final_vel.limit_length(speed)
	else:
		velocity_vec = Vector2.ZERO

func _compute_obstacle_repulsion_vector() -> Vector2:
	if not obstacle_avoidance_enabled or _nav_obstacles.size() == 0:
		return Vector2.ZERO

	var repulse := Vector2.ZERO
	for obs in _nav_obstacles:
		if not is_instance_valid(obs):
			continue
		var info = _get_obstacle_radius_and_worldpos(obs)
		var obs_pos: Vector2 = info.pos
		var obs_radius: float = float(info.radius)

		var to_enemy := global_position - obs_pos
		var dist := to_enemy.length()
		if dist <= 0.0001:
			repulse += Vector2(randf() - 0.5, randf() - 0.5).normalized() * obstacle_avoidance_strength
			continue

		# influence radius
		var influence_radius = max(obs_radius * obstacle_influence_multiplier, obs_radius + obstacle_influence_min)
		if dist >= influence_radius:
			continue

		var penetration = influence_radius - dist
		var dir_out := (to_enemy / dist).normalized()

		var strength_factor := 1.0
		if obs_radius > 0.0:
			if dist > obs_radius:
				var denom = max(0.0001, influence_radius - obs_radius)
				strength_factor = clamp(1.0 - ((dist - obs_radius) / denom), 0.0, 1.0)
			else:
				strength_factor = 1.0
		else:
			var denom = max(0.0001, influence_radius)
			strength_factor = clamp(1.0 - ((dist) / denom), 0.0, 1.0)

		var gain := obstacle_avoidance_strength * 0.5
		var mag = max(obstacle_avoidance_min_strength, gain * strength_factor)

		var push = dir_out * (mag * (penetration / max(influence_radius, 1.0)))
		repulse += push

	return repulse

# ------------------------------
func _perform_attack() -> void:
	if is_dead or not player:
		return

	print("[Enemy ATTACK] perform_attack START")

	attack_can_hit = true

	_play_anim_if_exists("attack")

	if is_instance_valid(weapon) and weapon.has_method("start_attack"):
		weapon.start_attack()

	# ⏱ keep hit window open briefly
	await get_tree().create_timer(0.2).timeout

	attack_can_hit = false
	print("[Enemy ATTACK] hit window CLOSED")

	attack_timer = attack_cooldown

# Called by weapon when it hits a body (weapon calls weapon_owner.weapon_notify_hit(body))
func weapon_notify_hit(body: Node) -> void:
	if is_dead or not attack_can_hit:
		return

	# ✅ MUST be the player's DamageCollision
	if not (body is Area2D) or body.name != "DamageCollision":
		print("[Enemy HIT] Ignored:", body.name)
		return

	var player := body.get_parent()
	if player == null:
		return

	print("[Enemy HIT] Hurtbox confirmed")

	# DAMAGE
	if player.has_method("apply_damage"):
		player.apply_damage(enemy_damage)

	# KNOCKBACK
	if player.has_method("external_knockback"):
		player.external_knockback(
			global_position,
			weapon.knockback_strength,
			enemy_damage,
			0.25
		)

# ------------------------------
func take_damage(amount: int, source_pos: Vector2, knockback_velocity_strength: float) -> void:
	if is_dead:
		return
	# light screen shake on enemy hit
	_debug_camera_lookup("Enemy took damage")
	var cam := get_viewport().get_camera_2d()
	if cam:
		cam.shake(2.0, 0.08)
		print("[Camera] camera shake")

	hp -= amount
	emit_signal("enemy_damaged", amount)

	# hit reaction visuals are still allowed
	# hit reaction visuals (SAFE)
	if body_anim != null \
	and body_anim.sprite_frames != null \
	and body_anim.sprite_frames.has_animation("hit"):
		body_anim.play("hit")

	if head_anim != null \
	and head_anim.sprite_frames != null \
	and head_anim.sprite_frames.has_animation("hit"):
		head_anim.play("hit")

	# ❌ suppress knockback during attack (windup + recovery)
	if state == ATTACK or attack_active:
		if _debug_enabled:
			print("[Enemy] Damage during attack — knockback ignored")
	else:
		_apply_knockback_from(source_pos, knockback_velocity_strength)

	if hp <= 0:
		_die()

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
	state = DEAD
	death_anim_locked = true

	if agent:
		agent.set_velocity(Vector2.ZERO)
		agent.avoidance_enabled = false

	velocity = Vector2.ZERO
	velocity_vec = Vector2.ZERO

	if weapon:
		weapon.queue_free()
		weapon = null

	if damage_area:
		damage_area.monitoring = false

	# ✅ FORCE death frames ONCE (bypass lock)
	if body_anim != null \
	and body_anim.sprite_frames != null \
	and body_anim.sprite_frames.has_animation("death"):
		body_anim.play("death")

	if head_anim != null \
	and head_anim.sprite_frames != null \
	and head_anim.sprite_frames.has_animation("death"):
		head_anim.play("death")

	# ✅ ALSO play AnimationPlayer for contrast
	if anim_player and anim_player.has_animation("death"):
		anim_player.play("death")

	emit_signal("enemy_died", self)
	call_deferred("_handle_corpse_lifecycle")

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
	return enemy_damage

func _handle_corpse_lifecycle() -> void:
	print("[Enemy CORPSE] waiting for death animation")

	if anim_player:
		await anim_player.animation_finished
		print("[Enemy CORPSE] death animation finished")

	await get_tree().create_timer(corpse_lifetime).timeout
	await _fade_out()
	queue_free()

func _fade_out() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, fade_duration)
	await tween.finished

func _debug_camera_lookup(context: String) -> void:
	var cams = get_tree().get_nodes_in_group("Camera")
	print("\n[CAM DEBUG]", context)
	print(" Cameras in group:", cams.size())

	for c in cams:
		print(
			" -", c.name,
			"| class:", c.get_class(),
			"| current:", c.current if "current" in c else "N/A",
			"| global_pos:", c.global_position
		)

	var viewport_cam = get_viewport().get_camera_2d()
	print(" Viewport camera:", viewport_cam)

func disable_ai_and_idle():
	ai_disabled = true

	attack_can_hit = false
	attack_active = false

	if agent:
		agent.set_velocity(Vector2.ZERO)

	velocity = Vector2.ZERO
	velocity_vec = Vector2.ZERO

	# force idle animation once
	_play_anim_if_exists("idle")

func update_weapon_layer():
	var target_parent: Node2D

	if vert_dir == "up":
		target_parent = $Graphics/WeaponPivotBack
	else:
		target_parent = $Graphics/WeaponPivotFront

	if weapon_pivot.get_parent() != target_parent:
		weapon_pivot.reparent(target_parent)
		weapon_pivot.position = Vector2.ZERO
