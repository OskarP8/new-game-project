extends Node2D
class_name Weapon

# Assigned by enemy via initialize(owner)
var weapon_owner = null  # expected to be the Enemy instance

# Cached nodes inside the weapon scene (found inside the weapon scene itself)
var sprite: AnimatedSprite2D = null
var anim_player: AnimationPlayer = null
var hitbox: Area2D = null

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
	# Try to locate pivot & holder on owner safely
	if not weapon_owner:
		push_error("[Weapon] initialize: owner is null")
		return

	weapon_pivot = weapon_owner.get_node_or_null("Graphics/WeaponPivot")
	if weapon_pivot == null:
		push_error("Weapon.initialize: owner missing Graphics/WeaponPivot -> check enemy scene.")
		return

	# Try to get holder, otherwise create it under pivot
	weapon_holder = weapon_pivot.get_node_or_null("WeaponHolder")
	if weapon_holder == null:
		weapon_holder = Node2D.new()
		weapon_holder.name = "WeaponHolder"
		weapon_pivot.add_child(weapon_holder)
		weapon_holder.position = Vector2.ZERO

	# Find visuals/hitbox *inside this weapon scene* (self)
	sprite = _find_child(self, AnimatedSprite2D)
	anim_player = _find_child(self, AnimationPlayer)
	hitbox = _find_child(self, Area2D)

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
		# ensure monitoring is off until attack
		hitbox.monitoring = false
		if not hitbox.is_connected("body_entered", Callable(self, "_on_hitbox_body_entered")):
			hitbox.body_entered.connect(Callable(self, "_on_hitbox_body_entered"))

	# Reparent the weapon into the holder immediately (safe)
	reparent_weapon()

	# reset hit targets list
	_hit_targets.clear()

	print("[Weapon] initialized for owner:", weapon_owner.name if weapon_owner else "null")

# ---------------------------
# Reparent to holder
# ---------------------------
func reparent_weapon() -> void:
	var current_parent := get_parent()
	if current_parent:
		current_parent.remove_child(self)
	if weapon_holder:
		weapon_holder.add_child(self)
		self.position = Vector2.ZERO
		self.rotation = 0
	else:
		push_warning("[Weapon] reparent_weapon: weapon_holder missing")

# ---------------------------
# Called every physics frame from owner (owner should call weapon.update_weapon(delta))
# ---------------------------
func update_weapon(delta: float) -> void:
	# If attacking, keep attack rotation/flip until animation signals end
	if attacking:
		return

	if not weapon_owner or not weapon_pivot or not weapon_holder:
		return

	# Determine facing from owner's player direction if available
	var facing_left: bool = false
	if weapon_owner.has_method("player") or ("player" in weapon_owner and weapon_owner.player):
		# safe access
		if weapon_owner.player:
			facing_left = weapon_owner.player.global_position.x < weapon_owner.global_position.x
			# keep owner facing state in sync
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

	# locate owner & target
	if not weapon_owner:
		return

	# Ensure pivot/holder present
	if not weapon_pivot or not weapon_holder:
		push_error("[Weapon] missing pivot/holder.")
		return

	# compute angle towards player if available
	if weapon_owner.player:
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
	if not attacking:
		return
	if not body:
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
# Utility: find first node of *class reference* in subtree (including node itself)
# Usage: _find_child(self, AnimatedSprite2D) or _find_child(self, AnimationPlayer)
# IMPORTANT: target_type must be a class reference, not a string or typed parameter.
# ---------------------------
func _find_child(node: Node, target_type) -> Node:
	if node == null:
		return null

	# Compare the node's class name to the target's class name
	if node.get_class() == target_type.get_class():
		return node

	for child in node.get_children():
		var found := _find_child(child, target_type)
		if found:
			return found

	return null
