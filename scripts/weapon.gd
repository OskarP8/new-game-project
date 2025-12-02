extends Node2D
class_name Weapon

# Assigned by enemy via initialize(owner)
var weapon_owner = null  # expected to be the Enemy instance

# Cached nodes inside the weapon scene (found inside the weapon scene itself)
var sprite: AnimatedSprite2D = null
var anim_player: AnimationPlayer = null
var hitbox: Area2D = null
var grip_node: Node2D = null

# Weapon transforms (we reparent into owner's pivot/holder)
var weapon_pivot: Node2D = null
var weapon_holder: Node2D = null

# Attack state
var attacking: bool = false
var attack_angle: float = 0.0
var attack_facing_left: bool = false
var post_attack_left: bool = false

# Per-attack seen targets (prevent multiple hits in a single attack)
var _hit_targets: Array = []

# ---------------------------
# Public initialization (call from owner right after instancing)
# Example:
#   var w = weapon_scene.instantiate()
#   add_child(w)        # optional (we reparent later)
#   w.initialize(self)
# ---------------------------
func initialize(owner) -> void:
	weapon_owner = owner
	if not weapon_owner:
		push_error("[Weapon] initialize: owner is null")
		return

	# find owner's pivot/holder
	weapon_pivot = weapon_owner.get_node_or_null("Graphics/WeaponPivot")
	if weapon_pivot == null:
		push_error("[Weapon] initialize: owner missing Graphics/WeaponPivot -> check enemy scene.")
		return

	weapon_holder = weapon_pivot.get_node_or_null("WeaponHolder")
	if weapon_holder == null:
		weapon_holder = Node2D.new()
		weapon_holder.name = "WeaponHolder"
		weapon_pivot.add_child(weapon_holder)
		weapon_holder.position = Vector2.ZERO

	# find visuals/hitbox/grip inside this weapon scene
	sprite = _find_child(self, "AnimatedSprite2D")
	anim_player = _find_child(self, "AnimationPlayer")
	hitbox = _find_child(self, "Area2D")
	grip_node = _find_child_named(self, "Grip") as Node2D

	# normalize sprite visual if present
	if sprite:
		sprite.flip_h = false
		sprite.scale.x = abs(sprite.scale.x)

	# connect anim finished safely if found
	if anim_player:
		if not anim_player.is_connected("animation_finished", Callable(self, "_on_anim_finished")):
			anim_player.animation_finished.connect(Callable(self, "_on_anim_finished"))

	# connect hitbox if present
	if hitbox:
		hitbox.monitoring = false
		if not hitbox.is_connected("body_entered", Callable(self, "_on_hitbox_body_entered")):
			hitbox.body_entered.connect(Callable(self, "_on_hitbox_body_entered"))

	# Reparent the weapon into the holder and align grip
	reparent_and_align_to_grip()

	_hit_targets.clear()

	# Flip holder to the correct side on spawn (based on player's position if available)
	if weapon_owner and weapon_owner.has_node("player") or ("player" in weapon_owner and weapon_owner.player):
		if weapon_owner.player:
			var spawn_left: bool = weapon_owner.player.global_position.x < weapon_owner.global_position.x
			weapon_holder.scale.x = -1 if spawn_left else 1
	else:
		# fallback: use owner's facing_left if present
		if "facing_left" in weapon_owner:
			weapon_holder.scale.x = -1 if bool(weapon_owner.facing_left) else 1

	print("[Weapon] initialized for owner:", weapon_owner.name if weapon_owner else "null")

# ---------------------------
# Reparent to holder and align Grip -> holder origin
# ---------------------------
func reparent_and_align_to_grip() -> void:
	# Save grip local offset (relative to weapon root)
	var grip_local := Vector2.ZERO
	if grip_node:
		# grip_node.position is local to weapon root
		grip_local = grip_node.position
	# Reparent
	var current_parent := get_parent()
	if current_parent:
		current_parent.remove_child(self)
	if weapon_holder:
		weapon_holder.add_child(self)
		# Position this weapon such that the grip_local point becomes (0,0) in holder space
		# i.e. self.position = -grip_local
		self.position = -grip_local
		self.rotation = 0
	else:
		push_warning("[Weapon] reparent_and_align_to_grip: weapon_holder missing")

# ---------------------------
# Called every physics frame from owner (owner should call weapon.update_weapon(delta))
# ---------------------------
func update_weapon(delta: float) -> void:
	# keep attack rotation until animation clears it
	if attacking:
		return

	if not weapon_owner or not weapon_pivot or not weapon_holder:
		return

	# Determine facing from owner's player direction if available
	var facing_left: bool = false
	if ("player" in weapon_owner) and weapon_owner.player:
		facing_left = weapon_owner.player.global_position.x < weapon_owner.global_position.x
		# keep owner facing state in sync if properties exist
		if "facing_left" in weapon_owner:
			weapon_owner.facing_left = facing_left
		if "post_attack_left" in weapon_owner:
			weapon_owner.post_attack_left = facing_left

	# Flip holder to mirror the entire weapon scene
	weapon_holder.scale.x = -1 if facing_left else 1

	# Idle rotation: reset pivot (weapon visuals rely on pivot)
	weapon_pivot.rotation = 0

	# ensure sprite not double-flipped
	if sprite:
		sprite.flip_h = false

# ---------------------------
# Start attack (called by owner)
# ---------------------------
func start_attack() -> void:
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

	# Play visuals
	if anim_player and anim_player.has_animation("attack"):
		anim_player.play("attack")
	elif sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("attack"):
		sprite.play("attack")

	# enable hitbox for duration of attack
	if hitbox:
		hitbox.monitoring = true

# ---------------------------
# End attack (called by anim finished or owner fallback)
# ---------------------------
func end_attack() -> void:
	attacking = false

	# reset transforms similar to player behaviour
	if weapon_pivot:
		weapon_pivot.rotation = 0
	if weapon_holder:
		weapon_holder.scale.x = -1 if post_attack_left else 1

	# stop / resume idle anim
	if anim_player and anim_player.has_animation("idle"):
		anim_player.play("idle")
	elif sprite and sprite.sprite_frames and sprite.sprite_frames.has_animation("idle"):
		sprite.play("idle")

	# disable hitbox
	if hitbox:
		hitbox.monitoring = false

	_hit_targets.clear()

# ---------------------------
# hitbox callback
# ---------------------------
func _on_hitbox_body_entered(body: Node) -> void:
	# Only valid during attack
	if not attacking or not body:
		return
	# Only hit the player group
	if not body.is_in_group("Player"):
		return

	# prevent multiple hits on same body in one attack
	for existing in _hit_targets:
		if existing == body:
			return
	_hit_targets.append(body)

	# tell owner to apply damage/knockback (owner handles actual damage function names)
	if weapon_owner and weapon_owner.has_method("weapon_notify_hit"):
		weapon_owner.weapon_notify_hit(body)
	else:
		# best-effort fallback: apply damage + knockback directly if methods exist
		if body.has_method("apply_damage") and weapon_owner and "attack_damage" in weapon_owner:
			body.apply_damage(weapon_owner.attack_damage)
		if body.has_method("external_knockback") and weapon_owner and "knockback_strength" in weapon_owner:
			body.external_knockback((body.global_position - weapon_owner.global_position).normalized() * weapon_owner.knockback_strength)

# ---------------------------
# Animation finished callback
# ---------------------------
func _on_anim_finished(anim_name: String) -> void:
	if anim_name.begins_with("attack"):
		end_attack()

# ---------------------------
# Utility: find first node by class name in subtree (including node itself)
# Usage: _find_child(self, "AnimatedSprite2D") or _find_child(self, "AnimationPlayer")
# Accepts strings for the class name (keeps parsing simple)
# ---------------------------
func _find_child(node: Node, target_class_name: String) -> Node:
	if node == null:
		return null
	# match exact class name
	if node.get_class() == target_class_name:
		return node
	# check inheritance using ClassDB
	if ClassDB.is_parent_class(node.get_class(), target_class_name):
		return node
	for child in node.get_children():
		var result = _find_child(child, target_class_name)
		if result:
			return result
	return null

# ---------------------------
# Utility: find node by name inside subtree
# ---------------------------
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
# Optional helper: adjust hitbox collision layer/mask when equipping for player vs enemy.
# Edit layer/mask bit numbers to match your project.
# ---------------------------
func equip_for_owner(kind: String) -> void:
	# Example bits (change to your project's mapping)
	# player body: 1, enemy body: 2, player weapon: 4, enemy weapon: 8
	if not hitbox:
		return
	if kind == "player":
		# weapon should be in player-weapon layer and hit enemy bodies
		hitbox.set_collision_layer_bit(2, false) # clear enemy-weapon bit
		hitbox.set_collision_layer_bit(3, true)  # set player-weapon bit (bit index 3 is layer 4)
		hitbox.set_collision_mask_bit(1, true)   # hit enemy body (layer 2)
	elif kind == "enemy":
		hitbox.set_collision_layer_bit(3, false)
		hitbox.set_collision_layer_bit(4, true)  # enemy-weapon -> layer index 4 (example)
		hitbox.set_collision_mask_bit(0, true)   # hit player body (layer 1)
