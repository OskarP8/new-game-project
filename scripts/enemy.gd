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

# sight smoothing / memory (kept minor for losing sight)
var time_since_seen: float = 0.0
var lose_sight_delay: float = 0.8

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

	# Agent tuning (do not assign navigation_map to the agent; engine manages that)
	if agent:
		# reasonable tolerances so it doesn't constantly consider itself "finished"
		agent.path_desired_distance = 2.0
		agent.target_desired_distance = 2.0
		# enable avoidance and set simple avoidance layers (agent will avoid NavigationObstacle2D set to same layer)
		agent.avoidance_enabled = true
		agent.avoidance_layers = 1               # pick a layer bit you use for obstacles (keep consistent)
		agent.avoidance_mask = 1                 # which avoidance layers this agent reacts to
		# radius is useful for avoidance; tune per-enemy
		if agent.radius == 0:
			agent.radius = 8.0

	# connect velocity callback (safe)
	if agent:
		var callable := Callable(self, "_on_agent_velocity")
		if agent.velocity_computed.is_connected(callable):
			agent.velocity_computed.disconnect(callable)
		agent.velocity_computed.connect(callable)

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

	# debug - show reachable once per frame if you want (can be noisy)
	if agent and _debug_enabled:
		# is_target_reachable() is cheap; use sparingly if you're seeing spam
		pass

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
# Chase: update the agent target every frame to player's position
# ------------------------------

func _process_chase(delta: float) -> void:
	if not player:
		_set_state(IDLE)
		return

	# First: try to see the player (line-of-sight)
	var seen: bool = _scan_for_player(chase_radius)

	# If we see the player, clamp the target to the navmesh and update the agent target.
	if seen:
		time_since_seen = 0.0
		if agent:
			# clamp to closest navmesh point so the agent target isn't inside obstacles
			var map_rid = agent.get_navigation_map()
			if map_rid != RID():
				var safe_target = NavigationServer2D.map_get_closest_point(map_rid, player.global_position)
				agent.target_position = safe_target
				last_seen_pos = safe_target
	else:
		# lost sight smoothing / start SEARCH after delay
		time_since_seen += delta
		if time_since_seen >= lose_sight_delay:
			_set_state(SEARCH)
			search_timer = search_duration
			if agent:
				agent.target_position = last_seen_pos
			if _debug_enabled:
				print("[Enemy DEBUG] Lost sight -> SEARCH. Last seen:", last_seen_pos)
			return

	# Attack check uses actual player distance (so close melee can still trigger)
	if global_position.distance_to(player.global_position) <= attack_range and attack_timer <= 0.0:
		_set_state(ATTACK)
		return

	# Move using navigation / fallback towards agent.target_position
	_update_agent_movement()

	# minimal debug (no per-frame spam)
	if _debug_enabled and agent and (Time.get_ticks_msec() % 1000) < 50:
		print("[Enemy DEBUG] chase -> seen:", seen, "agent.target:", agent.target_position, "nav_finished:", agent.is_navigation_finished())

func _process_search(delta: float) -> void:
	search_timer -= delta

	# Try to detect player while searching
	if _scan_for_player(chase_radius):
		_set_state(CHASE)
		return

	# If we have an agent, ensure it has a reasonable target to move to:
	if agent:
		# If the agent is finished but we're not at last_seen_pos, try to pick a reachable nearby pivot
		if agent.is_navigation_finished():
			var dist_to_last = global_position.distance_to(last_seen_pos)
			if dist_to_last > agent.target_desired_distance + 2.0:
				# try to find a reachable nearby point around last_seen_pos
				var fallback := _find_reachable_near(last_seen_pos, 10, 24.0)
				if fallback != Vector2.ZERO:
					agent.target_position = fallback
				else:
					# clamp to navmesh in case last_seen_pos was slightly outside
					var map_rid = agent.get_navigation_map()
					if map_rid != RID():
						var clamped = NavigationServer2D.map_get_closest_point(map_rid, last_seen_pos)
						if clamped != Vector2.ZERO:
							agent.target_position = clamped
						else:
							# keep last_seen_pos (agent will report finished if unreachable)
							agent.target_position = last_seen_pos
			else:
				# already close enough, just keep the last_seen_pos
				agent.target_position = last_seen_pos
		else:
			# agent still has an active path; ensure it's targeting last_seen_pos
			agent.target_position = last_seen_pos

	_update_agent_movement()

	# If we reached the last known position, wait a bit then return to IDLE
	if agent and agent.is_navigation_finished():
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
func _update_agent_movement() -> void:
	if not agent:
		velocity_vec = Vector2.ZERO
		return

	# If navigation finished, check whether we're actually at the target
	if agent.is_navigation_finished():
		var dist_to_target = global_position.distance_to(agent.target_position)
		# If we're still far, try to salvage movement:
		if dist_to_target > agent.target_desired_distance + 2.0:
			# Try to use next path position if available
			var next_pos: Vector2 = Vector2.ZERO
			if agent.has_method("get_next_path_position"):
				next_pos = agent.get_next_path_position()
			elif agent.has_method("get_next_location"):
				next_pos = agent.get_next_location()

			if next_pos != Vector2.ZERO:
				# we have a next node -> head there
				var dir_next = (next_pos - global_position)
				velocity_vec = dir_next.normalized() * speed if dir_next.length() > 0.01 else Vector2.ZERO
				return

			# Try clamping the agent.target_position to the navmesh (closest reachable point)
			var map_rid = agent.get_navigation_map()
			if map_rid != RID():
				var clamped = NavigationServer2D.map_get_closest_point(map_rid, agent.target_position)
				if clamped != Vector2.ZERO and clamped.distance_to(global_position) < dist_to_target:
					# Move toward clamped reachable point
					var dir_clamped = (clamped - global_position)
					velocity_vec = dir_clamped.normalized() * speed if dir_clamped.length() > 0.01 else Vector2.ZERO
					return

			# Last resort: try heading directly to the target_position (better than freezing)
			var dir_direct = (agent.target_position - global_position)
			velocity_vec = dir_direct.normalized() * speed if dir_direct.length() > 0.01 else Vector2.ZERO
			return
		else:
			# close enough: stop
			velocity_vec = Vector2.ZERO
			return

	# Otherwise, try to get a usable next path position from the agent
	var next_pos2: Vector2 = Vector2.ZERO
	if agent.has_method("get_next_path_position"):
		next_pos2 = agent.get_next_path_position()
	elif agent.has_method("get_next_location"):
		next_pos2 = agent.get_next_location()

	# fallback to target_position if we still didn't get a next node
	if next_pos2 == Vector2.ZERO and agent.target_position != Vector2.ZERO:
		var dist_to_target2 = global_position.distance_to(agent.target_position)
		if dist_to_target2 <= agent.target_desired_distance:
			velocity_vec = Vector2.ZERO
			if _debug_enabled:
				# occasional message only, avoid spam
				if Time.get_ticks_msec() % 2000 < 50:
					print("[Enemy DEBUG] Next_pos fallback is target_position but we're already within desired distance (", dist_to_target2, ")")
			return
		next_pos2 = agent.target_position

	# still nothing useful -> stop
	if next_pos2 == Vector2.ZERO:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			if Time.get_ticks_msec() % 2000 < 50:
				print("[Enemy DEBUG] Could not resolve next_pos from agent; next_pos==Vector2.ZERO, target_position:", agent.target_position)
		return

	# compute direction and velocity to next path point
	var dir: Vector2 = (next_pos2 - global_position)
	var dist = dir.length()
	if dist < 1.0:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			if Time.get_ticks_msec() % 2000 < 50:
				print("[Enemy DEBUG] next_pos too close to move towards (dist:", dist, ")")
		return

	velocity_vec = dir.normalized() * speed

	# debug info (very occasional)
	if _debug_enabled and (Time.get_ticks_msec() % 1500) < 50:
		print("[Enemy DEBUG] next_pos:", next_pos2, " target:", agent.target_position, " nav_finished:", agent.is_navigation_finished(), " velocity_vec:", velocity_vec)

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
	var to_player = player.global_position - origin
	if to_player.length() > radius:
		return false

	var angle_center = to_player.angle()
	var half_spread := deg_to_rad(60)
	var ray_count = max(detection_rays, 1)

	var space := get_world_2d().direct_space_state
	# NOTE: make sure your chest/walls CollisionShape2D use a layer that matches the OBSTACLE bit below.
	# Adjust bit (1<<4) to whatever you use for walls/obstacles. Here we test Player + Obstacle layer.
	var mask := (1 << 0) | (1 << 4)  # PLAYER + OBSTACLE

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

		# If this ray hits the player first → visible
		if collider.is_in_group("Player"):
			saw_player = true
			# we can return early if you prefer immediate detection:
			# return true
			# otherwise keep scanning other rays so a blocked ray doesn't cancel a later visible one
		else:
			# hit something else first (wall, chest) — this ray is blocked; keep checking other rays
			if _debug_enabled:
				# print occasionally to help debug which objects block LOS (not every frame)
				if Time.get_ticks_msec() % 2000 < 50:
					print("[Enemy DEBUG] LOS blocked by:", str(collider), "at", hit.get("position"))

	return saw_player
# ------------------------------
# Agent velocity callback
# ------------------------------
func _on_agent_velocity(safe_velocity: Vector2) -> void:
	# safe_velocity comes from the navigation agent (collision avoidance, path following)
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

func _find_reachable_near(center: Vector2, tries: int = 8, radius: float = 16.0) -> Vector2:
	# Returns a non-zero Vector2 if a reachable point on the navmesh is found near 'center'
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
			# require that the clamped point is meaningfully closer than the unreachable original
			if clamped.distance_to(global_position) < center.distance_to(global_position):
				return clamped
	# nothing found
	return Vector2.ZERO
