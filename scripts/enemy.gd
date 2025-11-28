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

# Nodes (ensure these exist or script will be tolerant)
@onready var agent: NavigationAgent2D = $Agent if has_node("Agent") else null
@onready var sprite: AnimatedSprite2D = $Sprite if has_node("Sprite") else null

# Weapon nodes (may be missing in some enemy scenes)
@onready var weapon_pivot: Node2D = get_node_or_null("Graphics/WeaponPivot")
# WeaponHolder is created if missing (keeps flipping separate from pivot rotation)
@onready var weapon_holder: Node2D = weapon_pivot.get_node_or_null("WeaponHolder") if weapon_pivot else null

# Weapon runtime vars
var current_weapon_scene: Node = null
var weapon_sprite: AnimatedSprite2D = null
var weapon_anim_player: AnimationPlayer = null
var weapon_grip_node: Node2D = null
var weapon_sprite_base_scale_x: float = 1.0
var weapon_root_base_pos: Vector2 = Vector2.ZERO
var current_weapon_root: Node = null

# State (AI)
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

# raycast eye offset
@export var eye_offset: Vector2 = Vector2(0, -8)

# weapon/attack visuals state
var attacking: bool = false
var has_weapon: bool = false
var facing_left: bool = false
var attack_angle: float = 0.0
var post_attack_left: bool = false

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

	# Ensure pivot/holder exist for weapon visuals
	if weapon_pivot and not weapon_holder:
		weapon_holder = Node2D.new()
		weapon_holder.name = "WeaponHolder"
		weapon_pivot.add_child(weapon_holder)
		weapon_holder.position = Vector2.ZERO
		weapon_holder.rotation = 0
		weapon_holder.scale = Vector2.ONE

	# Agent tuning (engine manages nav map)
	if agent:
		agent.path_desired_distance = 2.0
		agent.target_desired_distance = 2.0
		agent.avoidance_enabled = true
		agent.avoidance_layers = 1
		agent.avoidance_mask = 1
		if agent.radius == 0:
			agent.radius = 8.0

		# connect velocity callback (safe)
		var callable := Callable(self, "_on_agent_velocity")
		if agent.velocity_computed.is_connected(callable):
			agent.velocity_computed.disconnect(callable)
		agent.velocity_computed.connect(callable)

	_play_anim_if_exists("idle")
	_set_state(IDLE)
	set_physics_process(true)

	if _debug_enabled:
		print("[Enemy] ready — hp:", hp, "player found:", player != null)
	if agent:
		print("AGENT DEBUG:",
			" radius=", agent.radius,
			" avoidance_enabled=", agent.avoidance_enabled,
			" layers=", agent.avoidance_layers,
			" mask=", agent.avoidance_mask,
			" map=", agent.get_navigation_map()
		)

	# give one frame for engine to hook navigation map
	await get_tree().process_frame

	if agent:
		agent.avoidance_enabled = true
		agent.avoidance_layers = 1
		agent.avoidance_mask = 1
		if agent.radius < 1:
			agent.radius = 12

	if _debug_enabled and agent:
		print("AFTER FIX: radius=", agent.radius, "avoidance=", agent.avoidance_enabled)
		print("[KNIGHT MAP]", agent.get_navigation_map())

# ------------------------------
# Physics loop
# ------------------------------
func _physics_process(delta: float) -> void:
	detection_timer = max(0.0, detection_timer - delta)
	attack_timer = max(0.0, attack_timer - delta)

	# debug - show reachable once per frame if you want (can be noisy)
	if agent and _debug_enabled:
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

	# Attack check uses actual player distance
	if global_position.distance_to(player.global_position) <= attack_range and attack_timer <= 0.0:
		_set_state(ATTACK)
		return

	_update_agent_movement()

	# occasional debug
	if _debug_enabled and agent and (Time.get_ticks_msec() % 1000) < 50:
		print("[Enemy DEBUG] chase -> seen:", seen, "agent.target:", agent.target_position, "nav_finished:", agent.is_navigation_finished())

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
	# This state initiates an attack animation+logic
	# We ensure attack timing is respected here
	if attack_timer <= 0.0:
		# prepare attack: compute angle toward player and animate weapon (if present)
		_perform_attack()
		# attack flow is finished by animation callbacks (_on_weapon_animation_finished/_on_attack_finished)
		return
	# minor visual flip so sprite faces player
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
		if dist_to_target > agent.target_desired_distance + 2.0:
			var next_pos: Vector2 = Vector2.ZERO
			if agent.has_method("get_next_path_position"):
				next_pos = agent.get_next_path_position()
			elif agent.has_method("get_next_location"):
				next_pos = agent.get_next_location()

			if next_pos != Vector2.ZERO:
				var dir_next = (next_pos - global_position)
				velocity_vec = dir_next.normalized() * speed if dir_next.length() > 0.01 else Vector2.ZERO
				return

			var map_rid = agent.get_navigation_map()
			if map_rid != RID():
				var clamped = NavigationServer2D.map_get_closest_point(map_rid, agent.target_position)
				if clamped != Vector2.ZERO and clamped.distance_to(global_position) < dist_to_target:
					var dir_clamped = (clamped - global_position)
					velocity_vec = dir_clamped.normalized() * speed if dir_clamped.length() > 0.01 else Vector2.ZERO
					return

			var dir_direct = (agent.target_position - global_position)
			velocity_vec = dir_direct.normalized() * speed if dir_direct.length() > 0.01 else Vector2.ZERO
			return
		else:
			velocity_vec = Vector2.ZERO
			return

	var next_pos2: Vector2 = Vector2.ZERO
	if agent.has_method("get_next_path_position"):
		next_pos2 = agent.get_next_path_position()
	elif agent.has_method("get_next_location"):
		next_pos2 = agent.get_next_location()

	if next_pos2 == Vector2.ZERO and agent.target_position != Vector2.ZERO:
		var dist_to_target2 = global_position.distance_to(agent.target_position)
		if dist_to_target2 <= agent.target_desired_distance:
			velocity_vec = Vector2.ZERO
			if _debug_enabled:
				if Time.get_ticks_msec() % 2000 < 50:
					print("[Enemy DEBUG] Next_pos fallback is target_position but we're already within desired distance (", dist_to_target2, ")")
			return
		next_pos2 = agent.target_position

	if next_pos2 == Vector2.ZERO:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			if Time.get_ticks_msec() % 2000 < 50:
				print("[Enemy DEBUG] Could not resolve next_pos from agent; next_pos==Vector2.ZERO, target_position:", agent.target_position)
		return

	var dir: Vector2 = (next_pos2 - global_position)
	var dist = dir.length()
	if dist < 1.0:
		velocity_vec = Vector2.ZERO
		if _debug_enabled:
			if Time.get_ticks_msec() % 2000 < 50:
				print("[Enemy DEBUG] next_pos too close to move towards (dist:", dist, ")")
		return

	velocity_vec = dir.normalized() * speed

	if _debug_enabled and (Time.get_ticks_msec() % 1500) < 50:
		print("[Enemy DEBUG] next_pos:", next_pos2, " target:", agent.target_position, " nav_finished:", agent.is_navigation_finished(), " velocity_vec:", velocity_vec)

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
	# Adjust the mask bits to match your Player + Obstacle layers
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
	# safe_velocity comes from navigation agent (avoidance + path)
	if state in [CHASE, SEARCH, FLEE]:
		velocity_vec = safe_velocity.limit_length(speed)
	else:
		velocity_vec = Vector2.ZERO

# ------------------------------
# ATTACK / WEAPON integration
# ------------------------------
func _perform_attack() -> void:
	if not player:
		_set_state(IDLE)
		return

	# compute direction to player and set facing/angle
	var dir = (player.global_position - global_position)
	if dir.length() == 0:
		dir = Vector2.RIGHT
	attack_angle = dir.angle()
	if dir.x < 0:
		facing_left = true
	else:
		facing_left = false
	post_attack_left = facing_left

	# set attack cooldown so we don't spam
	attack_timer = attack_cooldown
	_set_state(ATTACK)
	attacking = true

	# rotate pivot: if facing_left, add PI so sprite visuals face correctly
	if weapon_pivot:
		weapon_pivot.rotation = attack_angle if not facing_left else attack_angle + PI

	# ensure holder exists and flip it for facing
	if weapon_holder:
		weapon_holder.scale.x = -1 if facing_left else 1

	# normalize inner visual scale & disable their own flip flags (we flip holder)
	var vis := weapon_sprite if weapon_sprite else null
	if vis:
		vis.scale.x = abs(vis.scale.x)
		vis.flip_h = false
	elif has_node("Graphics/WeaponPivot/Weapon"):
		# fallback to local path
		var v = get_node_or_null("Graphics/WeaponPivot/Weapon")
		if v and v is AnimatedSprite2D:
			v.scale.x = abs(v.scale.x)
			v.flip_h = false

	# Play the weapon attack animation (prefers AnimationPlayer)
	if weapon_anim_player and weapon_anim_player.has_animation("attack"):
		if weapon_anim_player.is_connected("animation_finished", Callable(self, "_on_weapon_animation_finished")):
			weapon_anim_player.disconnect("animation_finished", Callable(self, "_on_weapon_animation_finished"))
		weapon_anim_player.animation_finished.connect(Callable(self, "_on_weapon_animation_finished"))
		weapon_anim_player.play("attack")
	else:
		# fallback to AnimatedSprite2D
		if weapon_sprite and weapon_sprite.sprite_frames:
			if weapon_sprite.sprite_frames.has_animation("attack"):
				if not weapon_sprite.is_connected("animation_finished", Callable(self, "_on_attack_finished")):
					weapon_sprite.animation_finished.connect(Callable(self, "_on_attack_finished"))
				weapon_sprite.play("attack")
			else:
				# try direction variants
				var wanim := "attack_left" if facing_left else "attack_right"
				if weapon_sprite.sprite_frames.has_animation(wanim):
					if not weapon_sprite.is_connected("animation_finished", Callable(self, "_on_attack_finished")):
						weapon_sprite.animation_finished.connect(Callable(self, "_on_attack_finished"))
					weapon_sprite.play(wanim)
				else:
					# no weapon visual -> immediate finish after short delay
					# fallback: clear attacking quickly (prevents stuck)
					await get_tree().create_timer(0.12).timeout
					_on_attack_finished()

	# If we don't have a weapon visual, still apply damage if in range (instant)
	if not has_weapon:
		# melee hit check simple: apply if player still in attack_range
		if global_position.distance_to(player.global_position) <= attack_range:
			emit_signal("enemy_hit_player", attack_damage)
			if player.has_method("apply_damage"):
				player.apply_damage(attack_damage)
			_apply_knockback_to(player, knockback_strength)

# single handler for AnimatedSprite2D animation_finished
func _on_attack_finished() -> void:
	# cleanup after AnimatedSprite attack
	attacking = false
	# reset pivot
	if weapon_pivot:
		weapon_pivot.rotation = 0
	# ensure holder flip matches final facing
	if weapon_holder:
		weapon_holder.scale.x = -1 if post_attack_left else 1
	_set_state(CHASE)

	# small delay before allowing next attack (already set attack_timer earlier)
	# resume nothing else; AI will continue chasing

# weapon AnimationPlayer finished handler (signature: anim_name)
func _on_weapon_animation_finished(anim_name: String) -> void:
	if not anim_name.begins_with("attack"):
		return
	attacking = false
	# keep facing that the attack used
	facing_left = post_attack_left
	if weapon_pivot:
		weapon_pivot.rotation = 0
	if weapon_holder:
		weapon_holder.scale.x = -1 if facing_left else 1
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

	if target.has_method("external_knockback"):
		target.external_knockback(force)
		return

	if target is CharacterBody2D:
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

# ------------------------------
# Weapon equip / unequip / helpers
# ------------------------------
func unequip_weapon() -> void:
	if current_weapon_scene:
		current_weapon_scene.queue_free()
		current_weapon_scene = null
	weapon_sprite = null
	weapon_anim_player = null
	weapon_grip_node = null
	current_weapon_root = null
	has_weapon = false
	# reset pivot/holder
	if weapon_pivot:
		weapon_pivot.rotation = 0
	if weapon_holder:
		weapon_holder.scale = Vector2.ONE
	if _debug_enabled:
		print("[Enemy] Unequipped weapon")

# Accepts PackedScene / path string / InvItem (with scene_path)
func equip_weapon(packed_or_path) -> void:
	unequip_weapon()
	if packed_or_path == null or packed_or_path == "":
		if _debug_enabled:
			print("[Enemy] equip_weapon: unequip requested")
		return

	var packed = null
	if typeof(packed_or_path) == TYPE_STRING:
		packed = load(packed_or_path)
	elif packed_or_path is PackedScene:
		packed = packed_or_path
	else:
		# try InvItem style (duck-typed)
		if typeof(packed_or_path) == TYPE_OBJECT and "scene_path" in packed_or_path and packed_or_path.scene_path != "":
			packed = load(packed_or_path.scene_path)
		else:
			push_warning("equip_weapon: invalid argument type")
			return

	if not (packed is PackedScene):
		push_warning("equip_weapon: loaded resource is not a PackedScene -> " + str(packed))
		return

	# ensure holder exists
	if not weapon_holder and weapon_pivot:
		weapon_holder = weapon_pivot.get_node_or_null("WeaponHolder")
		if not weapon_holder:
			weapon_holder = Node2D.new()
			weapon_holder.name = "WeaponHolder"
			weapon_pivot.add_child(weapon_holder)

	weapon_holder.position = Vector2.ZERO
	weapon_holder.rotation = 0
	weapon_holder.scale.x = -1 if facing_left else 1

	# instantiate weapon under holder
	current_weapon_scene = packed.instantiate()
	weapon_holder.add_child(current_weapon_scene)
	current_weapon_scene.position = Vector2.ZERO
	current_weapon_scene.rotation = 0
	current_weapon_root = current_weapon_scene

	# try to find visuals & grip
	weapon_sprite = _find_child_of_type(current_weapon_scene, "AnimatedSprite2D")
	weapon_anim_player = _find_child_of_type(current_weapon_scene, "AnimationPlayer")
	weapon_grip_node = _find_child_named(current_weapon_scene, "Grip") as Node2D

	# align weapon so Grip sits at holder origin (hand)
	if weapon_grip_node != null:
		# compute offset so grip local pos maps to (0,0) of holder
		var grip_local = weapon_grip_node.position
		# set weapon root offset = -grip_local (so grip becomes (0,0))
		current_weapon_scene.position = -grip_local
		weapon_root_base_pos = current_weapon_scene.position
	else:
		weapon_root_base_pos = current_weapon_scene.position

	# store base scale
	if weapon_sprite:
		weapon_sprite_base_scale_x = abs(weapon_sprite.scale.x) if weapon_sprite.scale.x != 0 else 1.0
	else:
		weapon_sprite_base_scale_x = 1.0

	# connect animation finished
	if weapon_anim_player:
		if weapon_anim_player.is_connected("animation_finished", Callable(self, "_on_weapon_animation_finished")):
			weapon_anim_player.disconnect("animation_finished", Callable(self, "_on_weapon_animation_finished"))
		weapon_anim_player.animation_finished.connect(Callable(self, "_on_weapon_animation_finished"))
	if weapon_sprite:
		if not weapon_sprite.is_connected("animation_finished", Callable(self, "_on_attack_finished")):
			weapon_sprite.animation_finished.connect(Callable(self, "_on_attack_finished"))

	has_weapon = current_weapon_scene != null
	if _debug_enabled:
		print("[Enemy] equip_weapon -> scene:", packed, " sprite:", weapon_sprite, " anim_player:", weapon_anim_player, " grip:", weapon_grip_node)

# helper: play either AnimationPlayer or AnimatedSprite2D animation
func _play_weapon_anim(name: String) -> void:
	if weapon_anim_player and weapon_anim_player.has_animation(name):
		weapon_anim_player.play(name)
		return
	if weapon_sprite and weapon_sprite.sprite_frames and weapon_sprite.sprite_frames.has_animation(name):
		weapon_sprite.play(name)

# utility recursion to find first child with class name
func _find_child_of_type(node: Node, target_class_name: String) -> Node:
	if node == null:
		return null
	if node.get_class() == target_class_name:
		return node
	for child in node.get_children():
		var found = _find_child_of_type(child, target_class_name)
		if found:
			return found
	return null

func _find_child_named(node: Node, name: String) -> Node:
	if node == null:
		return null
	for child in node.get_children():
		if child.name == name:
			return child
		var found = _find_child_named(child, name)
		if found:
			return found
	return null
