# Enemy.gd
extends CharacterBody2D
class_name Enemy

# --- Stats ---
@export var max_hp: int = 10
@export var speed: float = 60.0
@export var notice_radius: float = 120.0   # short radius for first notice
@export var chase_radius: float = 220.0    # larger radius used while chasing
@export var attack_range: float = 24.0
@export var attack_damage: int = 10
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

# --- debugging helpers ---
func _set_state(new_state: int) -> void:
	if state == new_state:
		return
	var old = state
	state = new_state
	print("[Enemy] state:", old, "->", new_state, " at pos:", global_position)
	# play animation for state if available
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
		print("[Enemy] playing anim:", name)
	else:
		# fallback debug: print current sprite state
		print("[Enemy] anim not found:", name, " available:", sprite.sprite_frames.get_animation_names() if sprite and sprite.sprite_frames else "none")

func _ready() -> void:
	hp = max_hp
	player = get_tree().get_root().find_child("Player", true, false)
	if agent:
		agent.velocity_computed.connect(Callable(self, "_on_agent_velocity"))
		agent.target_desired_distance = 4.0
	# start in idle animation if possible
	_play_anim_if_exists("idle")
	_set_state(IDLE)
	set_physics_process(true)
	print("[Enemy] ready — hp:", hp, " player found:", player != null)

func _physics_process(delta: float) -> void:
	# timers
	detection_timer = max(0.0, detection_timer - delta)
	attack_timer = max(0.0, attack_timer - delta)

	# state machine
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
			# Attack is triggered from chase; maintain cooldown
			pass
		FLEE:
			_process_flee(delta)
		DEAD:
			pass

	# move using velocity_vec set by agent callback
	if velocity_vec.length_squared() > 0:
		velocity = velocity_vec
		move_and_slide()
	else:
		velocity = Vector2.ZERO

	# Debug each frame: print state + current animation occasionally (throttled would be better)
	# (keep this reasonably quiet in release)
	# print("[Enemy][DEBUG] state:", state, "vel:", velocity_vec, "anim:", sprite.animation if sprite else "none")

# ------------------------------
# State machines
# ------------------------------
func _process_idle(delta: float) -> void:
	# periodically scan for player
	if _scan_for_player(notice_radius):
		_set_state(ALERT)
		return
	# idle wandering could be placed here

func _process_alert(delta: float) -> void:
	# once alerted, immediately transition to chase
	if player:
		last_seen_pos = player.global_position
		_set_state(CHASE)

func _process_chase(delta: float) -> void:
	if not player:
		_set_state(IDLE)
		return

	if _scan_for_player(chase_radius):
		# update last seen and set agent to the player's position
		last_seen_pos = player.global_position
		agent.target_position = player.global_position
		print("[Enemy] chase: target_position set to player:", agent.target_position)
	else:
		# lost sight — switch to SEARCH
		_set_state(SEARCH)
		search_timer = search_duration
		agent.target_position = last_seen_pos
		print("[Enemy] lost sight → search target:", last_seen_pos)
		return

	var dist_to_player = global_position.distance_to(player.global_position)
	if dist_to_player <= attack_range and attack_timer <= 0.0:
		_set_state(ATTACK)
		print("[Enemy] in attack range — performing attack")
		_perform_attack()
		return

func _process_search(delta: float) -> void:
	# move to last seen pos, then look around for a bit
	search_timer -= delta
	# if we can re-see the player while searching, resume chase
	if _scan_for_player(chase_radius):
		_set_state(CHASE)
		return
	if search_timer <= 0.0:
		# give up and return to idle
		_set_state(IDLE)
		agent.target_position = global_position

func _process_flee(delta: float) -> void:
	# run away from player
	if not player:
		_set_state(IDLE)
		return
	var away_dir = (global_position - player.global_position)
	if away_dir.length() == 0:
		away_dir = Vector2.RIGHT
	var flee_target = global_position + away_dir.normalized() * 120.0
	agent.target_position = flee_target
	print("[Enemy] flee: target_position set to", flee_target)

# ------------------------------
# Detection helpers (raycasts)
# ------------------------------
func _scan_for_player(radius: float) -> bool:
	# rate-limit
	if detection_timer > 0.0:
		return false
	detection_timer = detection_interval

	if player == null:
		return false

	var origin: Vector2 = global_position
	var player_pos: Vector2 = player.global_position

	# distance check first
	if origin.distance_to(player_pos) > radius:
		return false

	# Typed raycast
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(origin, player_pos)
	query.exclude = [self]
	query.collide_with_bodies = true
	query.collide_with_areas = true

	var res: Dictionary = space.intersect_ray(query)
	if res.is_empty():
		return false

	# The collider may be any type, so we type it as Object
	var collider: Object = res.get("collider", null)
	if collider == null:
		return false

	# Walk up to find parent in Player group
	var node: Node = collider as Node
	while node != null and not node.is_in_group("Player"):
		node = node.get_parent()

	# if we found the Player → true
	if node != null and node.is_in_group("Player"):
		return true

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
	# debug
	# print("[Enemy] agent velocity:", velocity_vec)

# ------------------------------
# Attack (override in ranged/melee subclasses)
# ------------------------------
func _perform_attack() -> void:
	# generic melee: apply damage if close enough, then cooldown
	if not player:
		_set_state(IDLE)
		return

	# Face player — flip sprite horizontally if needed
	if sprite:
		sprite.flip_h = player.global_position.x < global_position.x

	# deal damage to player (emit a signal so camera/UI can react)
	var dmg := attack_damage
	print("[Enemy] dealing damage:", dmg)
	emit_signal("enemy_hit_player", dmg)
	# if player has method to receive damage:
	if player.has_method("apply_damage"):
		player.apply_damage(dmg)
	# knockback
	_apply_knockback_to(player, knockback_strength)
	attack_timer = attack_cooldown
	# after attack, resume chase
	_set_state(CHASE)

# ------------------------------
# Damage / death
# ------------------------------
func take_damage(amount: int, source_pos: Vector2=Vector2.ZERO, knockback_mult: float = 1.0) -> void:
	hp -= amount
	print("[Enemy] took damage:", amount, "hp now:", hp)
	emit_signal("enemy_damaged", amount)
	if hp <= 0 and state != DEAD:
		_die()
	else:
		# small stun/knockback
		_apply_knockback_from(source_pos, knockback_strength * knockback_mult)

func _apply_knockback_from(source_pos: Vector2, strength: float) -> void:
	var dir = (global_position - source_pos)
	if dir.length() == 0:
		dir = Vector2.RIGHT
	velocity_vec = dir.normalized() * strength

func _apply_knockback_to(target: Node, strength: float) -> void:
	if not target:
		return
	if target.has_method("apply_knockback"):
		target.apply_knockback((target.global_position - global_position).normalized() * strength)
	elif target is CharacterBody2D:
		target.velocity = (target.global_position - global_position).normalized() * strength

func _die() -> void:
	_set_state(DEAD)
	# play death animation if available
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("death"):
		sprite.play("death")
		print("[Enemy] playing death animation")
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
	# spawn world item if possible
	if world_item_scene:
		var world_item = world_item_scene.instantiate()
		if "item" in world_item:
			world_item.item = item_res
			world_item.quantity = 1
		world_item.global_position = global_position
		get_tree().current_scene.add_child(world_item)
		print("[Enemy] spawned loot at", global_position, "item:", item_res)
	else:
		print("[Enemy] dropped:", item_res)
