extends Node2D
class_name Weapon

# --- Collision Layers ---
const LAYER_PLAYER_BODY  = 1 << 0  # 1: player
const LAYER_WEAPON       = 1 << 2  # 3: weapon
const LAYER_WALLS        = 1 << 4  # 5: walls
const LAYER_ENEMY_BODY   = 1 << 5  # 6: enemy
const LAYER_DAMAGE       = 1 << 6  # 7: damage / hurtbox ✅

@export var weapon_damage: int = 10
@export var knockback_strength: float = 300.0

# Assigned by owner via initialize(owner)
var weapon_owner = null

# Cached nodes inside the weapon scene
var sprite: AnimatedSprite2D = null
var anim_player: AnimationPlayer = null
var hitbox: Area2D = null
var grip_node: Node2D = null
var _debug_enabled: bool = true

# Weapon transforms (reparented into owner's pivot/holder)
var weapon_pivot: Node2D = null
var weapon_holder: Node2D = null

# Attack state
var attacking: bool = false
var attack_angle: float = 0.0
var attack_facing_left: bool = false
var post_attack_left: bool = false

# Per-attack seen targets
var _hit_targets: Array = []

# ---------------------------
func initialize(owner, pivot: Node2D, holder: Node2D) -> void:
	weapon_owner = owner
	weapon_pivot = pivot
	weapon_holder = holder

	weapon_owner = owner
	if not weapon_owner:
		push_error("[Weapon] initialize: owner is null")
		return

	# find visuals/hitbox/grip inside this weapon scene
	sprite = _find_child(self, "AnimatedSprite2D")
	anim_player = _find_child(self, "AnimationPlayer")
	hitbox = _find_child(self, "Area2D")
	grip_node = _find_child_named(self, "Grip") as Node2D
	# --- DEBUG: Grip + node discovery ---
	if _debug_enabled:
		if grip_node:
			print("[Weapon DEBUG] Grip found:", grip_node, " pos:", grip_node.position)
		else:
			print("[Weapon DEBUG] Grip NOT found in weapon:", self.name, "children:", get_child_count())
			# list child names to help diagnose
			for i in range(get_child_count()):
				var c = get_child(i)
				print("  child[", i, "]:", c.name, " class:", c.get_class())
	# also dump animations available on the AnimatedSprite2D (if any)
	if sprite and sprite.sprite_frames and _debug_enabled:
		var anims = sprite.sprite_frames.get_animation_names()
		print("[Weapon DEBUG] sprite animations:", anims)
	# anim_player presence
	if anim_player and _debug_enabled:
		print("[Weapon DEBUG] anim_player exists on:", self.name)

	# normalize sprite visual if present
	if sprite:
		sprite.flip_h = false
		sprite.scale.x = abs(sprite.scale.x)

	# connect animation_finished signals (safe)
	if anim_player:
		if not anim_player.is_connected("animation_finished", Callable(self, "_on_anim_finished")):
			anim_player.animation_finished.connect(Callable(self, "_on_anim_finished"))

	# connect hitbox callback
	# connect hitbox callback (FORCED, SAFE)
	if hitbox:
		hitbox.monitoring = false
		hitbox.monitorable = true

		# disconnect any stale connections (important after reparent)
		# connect hitbox callback (Area2D → Area2D)
		if hitbox:
			hitbox.monitoring = false
			hitbox.monitorable = true

			if hitbox.area_entered.is_connected(_on_hitbox_area_entered):
				hitbox.area_entered.disconnect(_on_hitbox_area_entered)

			hitbox.area_entered.connect(_on_hitbox_area_entered)

			print("[Weapon DEBUG] hitbox ready:",
				"layer =", hitbox.collision_layer,
				"mask =", hitbox.collision_mask
			)

		print("[Weapon DEBUG] hitbox ready:",
			"layer =", hitbox.collision_layer,
			"mask =", hitbox.collision_mask
		)

	# Force initial visual state after reparent so weapon isn't stuck visually
	if sprite and sprite.sprite_frames:
		if sprite.sprite_frames.has_animation("idle"):
			sprite.play("idle")
			if _debug_enabled:
				print("[Weapon DEBUG] forced sprite.play('idle') after reparent")
	if anim_player:
		# only try to play idle if animation exists
		if anim_player.has_animation("idle"):
			anim_player.play("idle")
			if _debug_enabled:
				print("[Weapon DEBUG] anim_player.play('idle') after reparent")

	_hit_targets.clear()

	# Flip holder initial side depending on owner's player presence or facing flag
	var spawn_left: bool = false
	if weapon_owner and ("player" in weapon_owner) and weapon_owner.player:
		spawn_left = weapon_owner.player.global_position.x < weapon_owner.global_position.x
	elif "facing_left" in weapon_owner:
		spawn_left = bool(weapon_owner.facing_left)

	weapon_holder.scale.x = -1 if spawn_left else 1

	if _debug_enabled:
		print("[Weapon] initialized for owner:", weapon_owner.name if weapon_owner else "null")

# ---------------------------

# ---------------------------
func update_weapon(delta: float) -> void:
	# keep attack rotation until animation clears it
	if attacking:
		return

	if not weapon_owner or not weapon_pivot or not weapon_holder:
		return

	# Determine facing from owner's player if available
	var facing_left: bool = false
	if ("player" in weapon_owner) and weapon_owner.player:
		facing_left = weapon_owner.player.global_position.x < weapon_owner.global_position.x
		if "facing_left" in weapon_owner:
			weapon_owner.facing_left = facing_left
		if "post_attack_left" in weapon_owner:
			weapon_owner.post_attack_left = facing_left

	# Flip holder to mirror entire weapon scene
	weapon_holder.scale.x = -1 if facing_left else 1

	# Idle rotation: reset pivot
	weapon_pivot.rotation = 0

	# ensure sprite not double-flipped
	if sprite:
		sprite.flip_h = false

# ---------------------------
# ---------------------------
# Start attack (called by owner)
# ---------------------------
func start_attack() -> void:
	print("🗡 WEAPON START ATTACK")
	if attacking:
		return
	attacking = true
	_hit_targets.clear()

	if not weapon_owner:
		return
	if not weapon_pivot or not weapon_holder:
		push_error("[Weapon] missing pivot/holder.")
		return

	# compute angle towards player if available
	if ("player" in weapon_owner) and weapon_owner.player:
		var player_pos: Vector2 = weapon_owner.player.global_position
		var dir: Vector2 = player_pos - weapon_pivot.global_position
		attack_angle = dir.angle()
		attack_facing_left = dir.x < 0
		post_attack_left = attack_facing_left
	else:
		attack_angle = 0.0
		attack_facing_left = false
		post_attack_left = false

	# Apply rotation like player does
	weapon_pivot.rotation = attack_angle + PI if attack_facing_left else attack_angle

	# Flip holder
	weapon_holder.scale.x = -1 if attack_facing_left else 1

	# Play visuals: prefer AnimationPlayer but also start sprite frames if present.
	if anim_player and anim_player.has_animation("attack"):
		anim_player.play("attack")
		if _debug_enabled:
			print("[Weapon DEBUG] anim_player.play('attack') for", self.name)
	# Always try to play AnimatedSprite2D "attack" if present — many weapon scenes use sprite frames
	if sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("attack"):
		sprite.play("attack")
		if _debug_enabled:
			print("[Weapon DEBUG] sprite.play('attack') for", self.name)
	# enable hitbox
	if hitbox:
		hitbox.monitoring = true
		if _debug_enabled:
			print("[Weapon DEBUG] hitbox.monitoring = true for", self.name)

# ---------------------------
func end_attack() -> void:
	print("🛑 WEAPON END ATTACK")
	attacking = false

	# reset transforms similar to player behaviour
	if weapon_pivot:
		weapon_pivot.rotation = 0
	if weapon_holder:
		weapon_holder.scale.x = -1 if post_attack_left else 1

	# stop / resume idle anim: try AnimationPlayer first, otherwise fallback to sprite
	var did_idle = false
	if anim_player and anim_player.has_animation("idle"):
		anim_player.play("idle")
		did_idle = true
		if _debug_enabled:
			print("[Weapon] anim_player.play(idle)")
	if not did_idle and sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("idle"):
		sprite.play("idle")
		if _debug_enabled:
			print("[Weapon] sprite.play(idle)")

	# disable hitbox
	if hitbox:
		hitbox.monitoring = false
		if _debug_enabled:
			print("[Weapon] hitbox disabled after attack")

	_hit_targets.clear()

# ---------------------------
func _on_hitbox_area_entered(area: Area2D) -> void:
	if not attacking or area == null:
		return

	# Only accept DAMAGE layer
	if area.collision_layer != LAYER_DAMAGE:
		if _debug_enabled:
			print("[Weapon] Ignored non-damage area:", area.name)
		return

	# Prevent double hits
	if area in _hit_targets:
		return
	_hit_targets.append(area)

	var target := area.get_parent()
	if not target:
		return

	if _debug_enabled:
		print(
			"[Weapon HIT]",
			"weapon owner:", weapon_owner.name,
			"hit damage area:", area.name,
			"target:", target.name
		)

	# PLAYER → ENEMY
	if weapon_owner.is_in_group("Player") and target.has_method("take_damage"):
		target.take_damage(
			weapon_damage,
			weapon_owner.global_position,
			knockback_strength
		)

	# ENEMY → PLAYER
	elif weapon_owner.is_in_group("Enemy") and weapon_owner.has_method("weapon_notify_hit"):
		weapon_owner.weapon_notify_hit(area)

# ---------------------------
func _on_anim_finished(anim_name: String) -> void:
	# only treat attack end when animation begins with "attack"
	if anim_name.begins_with("attack"):
		end_attack()

# ---------------------------
func _find_child(node: Node, target_class_name: String) -> Node:
	if node == null:
		return null
	if node.get_class() == target_class_name:
		return node
	if ClassDB.is_parent_class(node.get_class(), target_class_name):
		return node
	for child in node.get_children():
		var result = _find_child(child, target_class_name)
		if result:
			return result
	return null

func _find_child_named(node: Node, target_name: String) -> Node:
	if node == null:
		return null
	if node.name == target_name:
		return node
	for child in node.get_children():
		var res = _find_child_named(child, target_name)
		if res:
			return res
	return null

# ---------------------------
# Safe equip helper: set hitbox layer/mask using integers (avoid set_collision_layer_bit issues)
func equip_for_owner(kind: String) -> void:
	if not hitbox:
		return

	# Weapon exists on weapon layer
	hitbox.collision_layer = LAYER_WEAPON

	# Weapon ONLY detects hurtboxes
	hitbox.collision_mask = LAYER_DAMAGE

	if _debug_enabled:
		print(
			"[Weapon] equipped for", kind,
			"| layer:", hitbox.collision_layer,
			"| mask:", hitbox.collision_mask
		)

func get_damage() -> int:
	return weapon_damage

func get_knockback() -> float:
	return knockback_strength
