extends CharacterBody2D

#@export var inv: Inv
@export var inventory: Inv = preload("res://inventory/playerinv.tres")

# ----------------------
# CONFIG
# ----------------------
const MAX_SPEED = 80
const ACCEL = 1500
const FRICTION = 600
const DEBUG = false

# ----------------------
# STATE
# ----------------------
var input = Vector2.ZERO
var vert_dir := "down"        # "up" or "down"
var hor_dir := "right"        # "left" or "right"
var last_dir := "down_right"  # combined for animation

var attacking = false
var has_weapon = true
var facing_left = false           # persistent facing state (keeps after attack)
var attack_angle: float = 0.0     # stored attack angle

# ----------------------
# NODES
# ----------------------
@onready var body_anim := $Graphics/Body as AnimatedSprite2D
@onready var head_anim := $Graphics/Head as AnimatedSprite2D
@onready var weapon_pivot := $Graphics/WeaponPivot as Node2D
@onready var weapon_anim := $Graphics/WeaponPivot/Weapon as AnimatedSprite2D

# ----------------------
# READY (connect once to avoid repeated connects)
# ----------------------
func _ready() -> void:
	if body_anim:
		body_anim.z_as_relative = true
	if head_anim:
		head_anim.z_as_relative = true
	if weapon_pivot:
		weapon_pivot.z_as_relative = true


# ----------------------
# MAIN LOOP
# ----------------------
func _physics_process(delta):
	if not attacking:
		player_movement(delta)

	_update_last_dir()
	update_animation()
	handle_attack()
	update_layers()

func _process(delta):
	# weapon pivot and player flip are updated every frame; during attack weapon uses stored angle
	if Input.is_action_just_pressed("test_add_item"):
		print("Adding test item to inventory")
		var test_item: InvItem = preload("res://resources/pitchfork_res.tres")
		collect(test_item)
	update_weapon_rotation()
	update_player_flip()
	sync_head_to_body()
	z_index = int(global_position.y)
	update_layers()
	#print("Player Y:", global_position.y)
# ----------------------
# INPUT
# ----------------------
func get_input() -> Vector2:
	var d = Vector2.ZERO
	d.x = int(Input.is_action_pressed("ui_right")) - int(Input.is_action_pressed("ui_left"))
	d.y = int(Input.is_action_pressed("ui_down")) - int(Input.is_action_pressed("ui_up"))
	return d.normalized()

# ----------------------
# MOVEMENT
# ----------------------
func player_movement(delta) -> void:
	input = get_input()

	if input != Vector2.ZERO:
		# movement physics
		velocity += input * ACCEL * delta
		velocity = velocity.limit_length(MAX_SPEED)

		# update vertical
		if input.y < 0:
			vert_dir = "up"
		elif input.y > 0:
			vert_dir = "down"

		# update horizontal and facing (movement sets facing)
		if input.x < 0:
			hor_dir = "left"
			facing_left = true
		elif input.x > 0:
			hor_dir = "right"
			facing_left = false
	else:
		# friction stop
		if velocity.length() > (FRICTION * delta):
			velocity -= velocity.normalized() * (FRICTION * delta)
		else:
			velocity = Vector2.ZERO

	move_and_slide()

# ----------------------
# HELPERS
# ----------------------
func _update_last_dir() -> void:
	# keep last_dir consistent for animation lookup
	last_dir = vert_dir + "_" + hor_dir

# ----------------------
# ATTACK
# ----------------------
func handle_attack() -> void:
	if not has_weapon or attacking or not body_anim:
		return

	var show_head = has_weapon and (vert_dir == "down")

	if Input.is_action_just_pressed("attack"):
		attacking = true

		# store attack angle once (weapon will point once then play attack anim)
		var mouse_pos = get_global_mouse_position()
		var dir = mouse_pos - weapon_pivot.global_position
		attack_angle = dir.angle()

		# determine attack-facing and persist it
		if dir.x < 0:
			facing_left = true
			hor_dir = "left"
		else:
			facing_left = false
			hor_dir = "right"

		_update_last_dir()

		var suffix = "_weapon"
		var base_dir = last_dir.replace("_left", "_right")

		# play body attack animation if exists
		var body_attack_name = "attack_" + base_dir + suffix
		if body_anim.sprite_frames and body_anim.sprite_frames.has_animation(body_attack_name):
			body_anim.play(body_attack_name)

		# play weapon attack animation (weapon will use stored rotation)
		if weapon_anim.sprite_frames and weapon_anim.sprite_frames.has_animation("attack"):
			weapon_anim.play("attack")

		# head attack
		if show_head and head_anim and head_anim.sprite_frames:
			var head_attack_name = "attack_" + base_dir + suffix
			if head_anim.sprite_frames.has_animation(head_attack_name):
				head_anim.play(head_attack_name)

# single handler connected in _ready
func _on_body_animation_finished() -> void:
	if attacking:
		_on_attack_finished()

func _on_attack_finished() -> void:
	attacking = false
	# after attack, weapon & body return to idle/walk via update_animation()
	update_animation()
	sync_head_to_body()

# ----------------------
# ANIMATION (body & head & weapon idle/walk)
# ----------------------
func update_animation():
	if attacking or not body_anim:
		return

	var suffix = "_weapon" if has_weapon else ""
	var show_head = has_weapon and ("down_left" in last_dir or "down_right" in last_dir)
	if head_anim:
		head_anim.visible = show_head

	var base_dir = last_dir.replace("_left", "_right")

	if input == Vector2.ZERO:
		# idle
		var body_idle = "idle_" + base_dir + suffix
		if body_anim.sprite_frames and body_anim.sprite_frames.has_animation(body_idle):
			body_anim.play(body_idle)

		if show_head and head_anim and head_anim.sprite_frames:
			if head_anim.sprite_frames.has_animation(body_idle):
				head_anim.play(body_idle)
	else:
		# diagonal movement
		if not has_weapon:
			if input.x < 0:
				last_dir = "down_left" if input.y >= 0 else "up_left"
			elif input.x > 0:
				last_dir = "down_right" if input.y >= 0 else "up_right"
			else:
				if input.y < 0:
					last_dir = "up_left" if "left" in last_dir else "up_right"
				elif input.y > 0:
					last_dir = "down_left" if "left" in last_dir else "down_right"

		base_dir = last_dir.replace("_left", "_right")
		var body_walk = "walk_" + base_dir + suffix
		if body_anim.sprite_frames and body_anim.sprite_frames.has_animation(body_walk):
			body_anim.play(body_walk)

		if show_head and head_anim and head_anim.sprite_frames:
			if head_anim.sprite_frames.has_animation(body_walk):
				head_anim.play(body_walk)

	if attacking or not body_anim:
		# when attacking, we don't change body/weapon animations here
		return

	if head_anim:
		head_anim.visible = show_head


	# Build idle / walk animation names; prefer exact left/right anims if present,
	# otherwise try right-side version and flip horizontally.
	if input == Vector2.ZERO:
		var target = "idle_" + base_dir + suffix
		if _play_with_optional_flip(body_anim, target):
			# body played
			pass
		else:
			# fallback: try replacing _left with _right and flip horizontally
			var alt = base_dir.replace("_left", "_right")
			target = "idle_" + alt + suffix
			if _play_with_optional_flip(body_anim, target, true):
				pass

		# head
		if show_head and head_anim:
			var head_target = "idle_" + base_dir + suffix
			_play_with_optional_flip(head_anim, head_target)

		# weapon idle
		if has_weapon and weapon_anim and weapon_anim.sprite_frames and weapon_anim.sprite_frames.has_animation("idle"):
			weapon_anim.play("idle")
	else:
		# walking
		var target_walk = "walk_" + base_dir + suffix
		if _play_with_optional_flip(body_anim, target_walk):
			pass
		else:
			var alt = base_dir.replace("_left", "_right")
			target_walk = "walk_" + alt + suffix
			if _play_with_optional_flip(body_anim, target_walk, true):
				pass

		# head
		if show_head and head_anim:
			var head_walk_target = "walk_" + base_dir + suffix
			_play_with_optional_flip(head_anim, head_walk_target)

		# weapon walk
		if has_weapon and weapon_anim and weapon_anim.sprite_frames and weapon_anim.sprite_frames.has_animation("walk"):
			weapon_anim.play("walk")

# helper: try to play anim, if it's a 'left' variant not present try to play the right variant & flip
func _play_with_optional_flip(anim_sprite: AnimatedSprite2D, anim_name: String, force_flip_if_left: bool=false) -> bool:
	if not anim_sprite or not anim_sprite.sprite_frames:
		return false

	var frames = anim_sprite.sprite_frames

	# Direct animation found
	if frames.has_animation(anim_name):
		anim_sprite.play(anim_name)
		anim_sprite.flip_h = anim_name.find("_left") != -1
		return true

	# Fallback: if forced and anim_name is left, try right version and flip
	if force_flip_if_left:
		var alt_name = anim_name.replace("_left", "_right")
		if frames.has_animation(alt_name):
			anim_sprite.play(alt_name)
			anim_sprite.flip_h = true
			return true

		return false

	# anim_name expected like "idle_down_left_weapon" or similar
	if not anim_sprite or not anim_sprite.sprite_frames:
		return false

	if anim_sprite.sprite_frames.has_animation(anim_name):
		anim_sprite.play(anim_name)
		# set flip state matching whether name contains "_left"
		if anim_name.find("_left") != -1:
			anim_sprite.flip_h = true
		else:
			anim_sprite.flip_h = false
		return true

	# if not found and caller requested fallback, attempt right-side version
	if force_flip_if_left:
		# replace "_left" with "_right" and play, but flip sprite horizontally
		var alt_name = anim_name.replace("_left", "_right")
		if anim_sprite.sprite_frames.has_animation(alt_name):
			anim_sprite.play(alt_name)
			anim_sprite.flip_h = true
			return true

	# not found
	return false

# ----------------------
# LAYER ORDER (relative within the player)
# ----------------------
func update_layers() -> void:
	if not body_anim or not weapon_pivot:
		return

	# base relative order inside the player
	# body always lowest, head always top
	if has_weapon and vert_dir == "down":
		# Facing down → weapon in front of body
		body_anim.z_index = 0
		weapon_pivot.z_index = 1
	else:
		# Facing up → weapon behind body
		weapon_pivot.z_index = 0
		body_anim.z_index = 1

	if head_anim:
		head_anim.z_index = 2  # always top within player


# ----------------------
# HEAD SYNC
# ----------------------
func sync_head_to_body() -> void:
	if not head_anim or not head_anim.visible or not body_anim:
		return

	var b_name = body_anim.animation
	var h_name = head_anim.animation
	if not b_name or not h_name:
		return

	if body_anim.sprite_frames and head_anim.sprite_frames:
		if body_anim.sprite_frames.has_animation(b_name) and head_anim.sprite_frames.has_animation(h_name):
			var b_count = body_anim.sprite_frames.get_frame_count(b_name)
			var h_count = head_anim.sprite_frames.get_frame_count(h_name)
			if b_count > 0 and h_count > 0:
				head_anim.frame = int(body_anim.frame * h_count / b_count)
				return

	# fallback
	head_anim.frame = body_anim.frame

# ----------------------
# WEAPON ROTATION (attack uses stored angle; idle/walk has rotation 0)
# ----------------------
func update_weapon_rotation() -> void:
	if not has_weapon or not weapon_anim or not weapon_pivot:
		return

	if attacking:
		# apply stored angle every frame while attacking; ensure scale matches facing_left
		if facing_left:
			weapon_anim.scale.x = -1
			weapon_pivot.rotation = attack_angle + PI
		else:
			weapon_anim.scale.x = 1
			weapon_pivot.rotation = attack_angle
	else:
		# idle/walk: weapon faces player facing (no rotation)
		if facing_left:
			weapon_anim.scale.x = -1
		else:
			weapon_anim.scale.x = 1
		weapon_pivot.rotation = 0

# ----------------------
# PLAYER FLIP
# ----------------------
func update_player_flip() -> void:
	# use persistent facing_left so it doesn't revert after attack
	if body_anim:
		body_anim.flip_h = facing_left
	if head_anim:
		head_anim.flip_h = facing_left

func collect(item: InvItem, quantity: int = 1) -> void:
	var entry = InventoryEntry.new()
	entry.item = item
	entry.quantity = quantity
	inventory.add_item(entry)   # ✅ correct method

func get_inventory() -> Inv:
	return inventory

func add_to_inventory(item: InvItem, quantity: int) -> void:
	var entry = InventoryEntry.new()
	entry.item = item
	entry.quantity = quantity
	inventory.add_item(entry)   # emits signal → UI updates
