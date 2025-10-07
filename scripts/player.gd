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
var attack_flip: bool = false   # true when attack was aimed to the left

var current_weapon_scene: Node = null
var weapon_sprite: AnimatedSprite2D = null
var weapon_anim_player: AnimationPlayer = null
# store facing at the start of the attack so it doesn't change mid-attack
var attack_facing_left: bool = false

# store base scale magnitude of the weapon sprite so flips preserve size
var weapon_sprite_base_scale_x: float = 1.0


# ----------------------
# NODES
# ----------------------
@onready var body_anim := $Graphics/Body as AnimatedSprite2D
@onready var head_anim := $Graphics/Head as AnimatedSprite2D
@onready var weapon_pivot := $Graphics/WeaponPivot as Node2D
@onready var weapon_anim := $Graphics/WeaponPivot/Weapon as AnimatedSprite2D
@onready var sword_anim_player := $Graphics/WeaponPivot/Sword/AnimationPlayer

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
	var sword_scene: PackedScene = preload("res://scenes/Weapons/sword.tscn")
	equip_weapon(sword_scene)


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
	if not has_weapon or attacking:
		return

	if Input.is_action_just_pressed("attack"):
		attacking = true

		# compute facing & angle first
		var mouse_pos = get_global_mouse_position()
		var dir = mouse_pos - weapon_pivot.global_position
		attack_angle = dir.angle()

		if dir.x < 0:
			facing_left = true
			hor_dir = "left"
		else:
			facing_left = false
			hor_dir = "right"

		_update_last_dir()

		# Determine suffix for left or right animations
		var direction_suffix = "_left" if facing_left else "_right"

		# Play weapon attack animation
		if weapon_anim and weapon_anim.sprite_frames:
			var weapon_attack_name = "attack" + direction_suffix
			if weapon_anim.sprite_frames.has_animation(weapon_attack_name):
				weapon_anim.play(weapon_attack_name)

		# Play body attack animation
		var suffix = "_weapon"
		var body_attack_name = "attack_" + vert_dir + direction_suffix + suffix
		if body_anim and body_anim.sprite_frames and body_anim.sprite_frames.has_animation(body_attack_name):
			body_anim.play(body_attack_name)

		# Play head attack animation
		var head_attack_name = "attack_" + vert_dir + direction_suffix + suffix
		if head_anim and head_anim.sprite_frames and head_anim.sprite_frames.has_animation(head_attack_name):
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
func update_animation() -> void:
	if attacking or not body_anim:
		return

	# --- Setup ---
	var suffix = "_weapon" if has_weapon else ""
	var show_head = has_weapon and ("down_left" in last_dir or "down_right" in last_dir)
	if head_anim:
		head_anim.visible = show_head

	# --- Determine movement state ---
	var is_idle = input == Vector2.ZERO
	var base_dir = last_dir.replace("_left", "_right")

	# --- Choose animation prefix ---
	var prefix = "idle_" if is_idle else "walk_"
	var anim_name = prefix + base_dir + suffix

	# --- BODY ANIMATION ---
	if body_anim and body_anim.sprite_frames:
		if not _play_with_optional_flip(body_anim, anim_name):
			# Try right version + flip if left version missing
			var alt = base_dir.replace("_left", "_right")
			_play_with_optional_flip(body_anim, prefix + alt + suffix, true)

	# --- HEAD ANIMATION ---
	if show_head and head_anim and head_anim.sprite_frames:
		_play_with_optional_flip(head_anim, anim_name)

	# --- WEAPON ANIMATION ---
	if has_weapon and weapon_anim and weapon_anim.sprite_frames:
		var weapon_anim_name = "idle" if is_idle else "walk"
		if weapon_anim.sprite_frames.has_animation(weapon_anim_name):
			weapon_anim.play(weapon_anim_name)


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
func update_weapon_rotation():
	if not has_weapon or not weapon_pivot:
		return

	var sprite := weapon_sprite if weapon_sprite else weapon_anim
	if not sprite:
		return

	if attacking:
		# Use stored attack_angle instead of following the mouse
		var angle = attack_angle

		# Flip sprite depending on original facing direction at attack start
		if facing_left:
			sprite.scale.x = -weapon_sprite_base_scale_x
			weapon_pivot.rotation = angle + PI
		else:
			sprite.scale.x = weapon_sprite_base_scale_x
			weapon_pivot.rotation = angle
	else:
		# Idle/walk: keep weapon aligned with player facing
		sprite.scale.x = -weapon_sprite_base_scale_x if facing_left else weapon_sprite_base_scale_x
		weapon_pivot.rotation = 0
# ----------------------
# PLAYER FLIP
# ----------------------
# ----------------------
# PLAYER FLIP
# ----------------------
func update_player_flip() -> void:
	# Flip body and head visually based on facing_left
	if body_anim:
		body_anim.flip_h = facing_left
	if head_anim:
		head_anim.flip_h = facing_left

	# Important: weapon sprite flip handled only in update_weapon_rotation()

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

# equip a weapon from a PackedScene or path (pass a PackedScene or a string path)
func equip_weapon(packed_or_path) -> void:
	# free old
	if current_weapon_scene:
		current_weapon_scene.queue_free()
		current_weapon_scene = null
		weapon_sprite = null
		weapon_anim_player = null

	var packed: PackedScene = null
	if typeof(packed_or_path) == TYPE_STRING:
		packed = load(packed_or_path)
	elif packed_or_path is PackedScene:
		packed = packed_or_path
	else:
		push_warning("equip_weapon: invalid argument")
		return

	if not packed:
		push_warning("equip_weapon: could not load scene")
		return

	current_weapon_scene = packed.instantiate()
	weapon_pivot.add_child(current_weapon_scene)
	current_weapon_scene.position = Vector2.ZERO

	# find sprite & animationplayer (recursive)
	weapon_sprite = _find_child_of_type(current_weapon_scene, "AnimatedSprite2D")
	weapon_anim_player = _find_child_of_type(current_weapon_scene, "AnimationPlayer")
	if weapon_sprite:
	# keep the absolute base scale so we can flip by setting sign only
		weapon_sprite_base_scale_x = abs(weapon_sprite.scale.x) if weapon_sprite.scale.x != 0 else 1.0
	else:
		weapon_sprite_base_scale_x = 1.0


	# connect animation_finished if we have an AnimationPlayer
	if weapon_anim_player:
		# disconnect first to be safe
		if weapon_anim_player.is_connected("animation_finished", Callable(self, "_on_weapon_animation_finished")):
			weapon_anim_player.disconnect("animation_finished", Callable(self, "_on_weapon_animation_finished"))
		weapon_anim_player.animation_finished.connect(Callable(self, "_on_weapon_animation_finished"))

	has_weapon = weapon_sprite != null or weapon_anim_player != null
	print("[player] equip_weapon. sprite:", weapon_sprite, "anim_player:", weapon_anim_player)

# recursive search for first child of specific class
# Recursive search for the first child of a specific class name
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

func _on_weapon_animation_finished(anim_name: String) -> void:
	if anim_name == "attack":
		attacking = false
		# reset/return to idle/walk visuals
		update_animation()
		# ensure weapon pivot rotation reset
		weapon_pivot.rotation = 0
		print("[player] weapon attack finished; attacking set false")
		# ensure weapon pivot rotation reset
		weapon_pivot.rotation = 0
		print("[player] weapon attack finished; attacking set false")
