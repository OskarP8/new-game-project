extends CharacterBody2D

#@export var inv: Inv
@export var inventory: Inv = preload("res://inventory/inv.tres")

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
var post_attack_left: bool = false
var weapon_sprite_base_pos: Vector2 = Vector2.ZERO
# store base scale magnitude of the weapon sprite so flips preserve size
var weapon_sprite_base_scale_x: float = 1.0
# holder under weapon_pivot that we flip/scale/position
var weapon_holder: Node2D = null
# node inside the weapon scene that we treat as the 'visual root' (the instanced scene root)
var current_weapon_root: Node = null
# optional grip node found inside the weapon scene
var weapon_grip_node: Node2D = null
# store transforms so we can reset safely
var weapon_holder_base_scale := Vector2.ONE
var weapon_root_base_pos := Vector2.ZERO



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

		var mouse_pos = get_global_mouse_position()
		var dir = mouse_pos - weapon_pivot.global_position
		attack_angle = dir.angle()

		# Determine facing direction
		if dir.x < 0:
			facing_left = true
			hor_dir = "left"
		else:
			facing_left = false
			hor_dir = "right"

		attack_facing_left = facing_left
		post_attack_left = facing_left
		_update_last_dir()

		# Rotate pivot to aim (optional)
		weapon_pivot.rotation = attack_angle if not facing_left else attack_angle + PI

		# Flip holder, not the sprite
		var holder := weapon_pivot.get_node_or_null("WeaponHolder")
		if holder:
			holder.scale.x = -1 if facing_left else 1

		# Normalize sprite scale
		var vis := weapon_sprite if weapon_sprite else weapon_anim
		if vis:
			vis.scale.x = abs(vis.scale.x)
			vis.flip_h = false

		# --- Play single "attack" animation ---
		if weapon_anim_player:
			if weapon_anim_player.has_animation("attack"):
				weapon_anim_player.play("attack")
		else:
			# fallback to AnimatedSprite2D frames if present
			var vis_weapon := weapon_sprite if weapon_sprite else weapon_anim
			if vis_weapon and vis_weapon.sprite_frames:
				if vis_weapon.sprite_frames.has_animation("attack"):
					vis_weapon.play("attack")
					# ensure we get notified when the anim finishes so we can reset state
					if not vis_weapon.is_connected("animation_finished", Callable(self, "_on_attack_finished")):
						vis_weapon.animation_finished.connect(Callable(self, "_on_attack_finished"))
				elif vis_weapon.sprite_frames.has_animation("attack_right") or vis_weapon.sprite_frames.has_animation("attack_left"):
					var wanim := "attack_left" if facing_left else "attack_right"
					if vis_weapon.sprite_frames.has_animation(wanim):
						vis_weapon.play(wanim)
						if not vis_weapon.is_connected("animation_finished", Callable(self, "_on_attack_finished")):
							vis_weapon.animation_finished.connect(Callable(self, "_on_attack_finished"))

		# --- Body/head attack animations (auto-flip if left anim missing) ---
		var suffix = "_weapon"
		var body_attack_name = "attack_" + vert_dir + "_" + hor_dir + suffix

		if body_anim and body_anim.sprite_frames:
			if not _play_with_optional_flip(body_anim, body_attack_name):
				# fallback to right version + flip if left version missing
				var alt = body_attack_name.replace("_left", "_right")
				_play_with_optional_flip(body_anim, alt, true)

		if head_anim and head_anim.sprite_frames:
			if not _play_with_optional_flip(head_anim, body_attack_name):
				var alt = body_attack_name.replace("_left", "_right")
				_play_with_optional_flip(head_anim, alt, true)

# single handler connected in _ready
func _on_body_animation_finished() -> void:
	if attacking:
		_on_attack_finished()

func _on_attack_finished() -> void:
	# ✅ Reset attack state
	attacking = false
	facing_left = post_attack_left

	# ✅ Reset pivot rotation (important for AnimatedSprite2D weapons)
	if weapon_pivot:
		weapon_pivot.rotation = 0

	# ✅ Reset holder flip to match final facing
	if weapon_holder:
		weapon_holder.scale.x = -1 if facing_left else 1

	# ✅ Play idle/walk animation again for weapon
	if has_weapon:
		if input == Vector2.ZERO:
			_play_weapon_anim("idle")
		else:
			_play_weapon_anim("walk")

	# ✅ Resume body/head animations
	update_animation()
	sync_head_to_body()

	if DEBUG:
		print("[player] _on_attack_finished() — reset rotation, facing_left:", facing_left)
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

# -------------------------------------------------------------------------
# UPDATE WEAPON ROTATION (flips from origin)
# -------------------------------------------------------------------------
func update_weapon_rotation():
	if not has_weapon or not weapon_pivot or not weapon_holder:
		return

	# Decide facing only when not attacking
	if attacking:
		# during an attack we keep the pivot/holder as set when attack started
		return

	if input != Vector2.ZERO:
		# movement updates facing
		facing_left = input.x < 0
		post_attack_left = facing_left
	else:
		# when idle keep whatever side we ended on
		facing_left = post_attack_left

	# set holder flip (flip the holder's x scale so the whole weapon scene mirrors around the pivot)
	weapon_holder.scale.x = -1 if facing_left else 1
	# ensure inner visuals don't do their own flip (we rely on holder)
	if weapon_sprite:
		weapon_sprite.flip_h = false
	if weapon_anim:
		weapon_anim.flip_h = false

	# reset any pivot rotation for idle/walk
	weapon_pivot.rotation = 0

	# optional debug
	if DEBUG:
		print("[weapon] holder.scale.x:", weapon_holder.scale.x, "facing_left:", facing_left)

# ----------------------
# PLAYER FLIP
# ----------------------
func update_player_flip() -> void:
	# Flip body and head visually based on facing_left
	if body_anim:
		body_anim.flip_h = facing_left
	if head_anim:
		head_anim.flip_h = facing_left
	var holder := weapon_pivot.get_node_or_null("WeaponHolder")
	if holder:
		holder.scale.x = -1 if facing_left else 1

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

# -------------------------------------------------------------------------
# EQUIP WEAPON
# -------------------------------------------------------------------------
func equip_weapon(packed_or_path) -> void:
	# --- 1️⃣ Remove old weapon if exists
	if current_weapon_scene:
		current_weapon_scene.queue_free()
		current_weapon_scene = null
		weapon_sprite = null
		weapon_anim_player = null

	# --- 2️⃣ Load scene safely
	var packed = null

	if typeof(packed_or_path) == TYPE_STRING:
		packed = load(packed_or_path)
	elif packed_or_path is PackedScene:
		packed = packed_or_path
	elif packed_or_path is InvItem:
		if packed_or_path.scene_path != "":
			packed = load(packed_or_path.scene_path)
		else:
			push_warning("equip_weapon: InvItem has no valid scene_path")
			return
	else:
		push_warning("equip_weapon: invalid argument type")
		return

	# ✅ Extra type check
	if not (packed is PackedScene):
		push_warning("equip_weapon: loaded resource is not a PackedScene → " + str(packed))
		return

	# --- 3️⃣ Ensure WeaponHolder exists
	var holder: Node2D = weapon_pivot.get_node_or_null("WeaponHolder")
	if holder == null:
		holder = Node2D.new()
		holder.name = "WeaponHolder"
		weapon_pivot.add_child(holder)
		print("[equip_weapon] Created WeaponHolder under WeaponPivot")

	holder.position = Vector2.ZERO
	holder.rotation = 0
	holder.scale.x = -1 if facing_left else 1  # maintain flip direction

	# --- 4️⃣ Instantiate weapon and attach to holder
	current_weapon_scene = packed.instantiate()
	holder.add_child(current_weapon_scene)
	current_weapon_scene.position = Vector2.ZERO
	current_weapon_scene.rotation = 0

	# --- 5️⃣ Find important nodes
	weapon_sprite = _find_child_of_type(current_weapon_scene, "AnimatedSprite2D")
	weapon_anim_player = _find_child_of_type(current_weapon_scene, "AnimationPlayer")

	# --- 6️⃣ Store clean base scale for flipping logic
	if weapon_sprite:
		weapon_sprite_base_scale_x = abs(weapon_sprite.scale.x) if weapon_sprite.scale.x != 0 else 1.0
	else:
		weapon_sprite_base_scale_x = 1.0

	# --- 7️⃣ Safely connect animation finished signal
	if weapon_anim_player:
		if weapon_anim_player.is_connected("animation_finished", Callable(self, "_on_weapon_animation_finished")):
			weapon_anim_player.disconnect("animation_finished", Callable(self, "_on_weapon_animation_finished"))
		weapon_anim_player.animation_finished.connect(Callable(self, "_on_weapon_animation_finished"))

	# --- 8️⃣ Store state
	has_weapon = weapon_sprite != null or weapon_anim_player != null
	print("[player] equip_weapon → sprite:", weapon_sprite, "anim_player:", weapon_anim_player, "holder.scale.x:", holder.scale.x)

func _play_weapon_anim(name: String) -> void:
	if weapon_anim_player and weapon_anim_player.has_animation(name):
		weapon_anim_player.play(name)
		return

	var vis := weapon_sprite if weapon_sprite else weapon_anim
	if vis and vis.sprite_frames and vis.sprite_frames.has_animation(name):
		vis.play(name)

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

# -------------------------------------------------------------------------
# ON WEAPON ATTACK FINISHED
# -------------------------------------------------------------------------
func _on_weapon_animation_finished(anim_name: String) -> void:
	# only care about attack animations
	if not anim_name.begins_with("attack"):
		return

	# clear attacking state
	attacking = false

	# ensure we keep the facing that the attack used
	facing_left = post_attack_left

	# Reset pivot rotation (attack used stored attack_angle)
	weapon_pivot.rotation = 0

	# After attack, set holder flip so weapon visually stays on attacked side
	if weapon_holder:
		weapon_holder.scale.x = -1 if facing_left else 1

	# If we had no Grip and recorded sprite offsets, ensure root/visual is mirrored properly
	if not weapon_grip_node and current_weapon_root:
		var sign = -1 if facing_left else 1
		if weapon_sprite:
			weapon_sprite.position.x = weapon_root_base_pos.x * sign
		elif weapon_anim:
			weapon_anim.position.x = weapon_root_base_pos.x * sign

	# resume idle/walk weapon anim
	if input == Vector2.ZERO:
		_play_weapon_anim("idle")
	else:
		_play_weapon_anim("walk")

	# resume body/head
	update_animation()
	sync_head_to_body()

	if DEBUG:
		print("[player] _on_weapon_animation_finished -> facing_left:", facing_left, "holder.scale.x:", weapon_holder.scale.x)

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
