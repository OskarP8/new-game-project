extends CharacterBody2D

signal lives_changed(current_lives: int)
signal life_lost(current_lives: int)
signal player_died

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
var weapon_logic: Node = null

var attacking = false
var has_weapon = false
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
var nearby_item: WorldItem = null
var knockback_force: Vector2 = Vector2.ZERO
var default_lives = 5
var dead: bool = false

# ----------------------
# NODES
# ----------------------
@onready var body_anim := $Graphics/Body as AnimatedSprite2D
@onready var head_anim := $Graphics/Head as AnimatedSprite2D
@onready var weapon_pivot := $Graphics/WeaponPivot as Node2D
@onready var weapon_anim := $Graphics/WeaponPivot/Weapon as AnimatedSprite2D
# sword_anim_player node reference kept in case it exists in tree
@onready var sword_anim_player := $Graphics/WeaponPivot/Sword/AnimationPlayer
@onready var lives: CanvasLayer = $Lives

func _dummy_set(v): pass

# ----------------------
# READY
# ----------------------
func _ready() -> void:
	life_lost.connect(_on_life_lost)
	player_died.connect(_on_player_died)

	if body_anim:
		body_anim.z_as_relative = true
	if head_anim:
		head_anim.z_as_relative = true
	if weapon_pivot:
		weapon_pivot.z_as_relative = true

	# find existing holder if present (safety)
	weapon_holder = weapon_pivot.get_node_or_null("WeaponHolder") if weapon_pivot else null
	if not weapon_holder and weapon_pivot:
		# create holder lazily so we always have a consistent node to flip/scale/position
		weapon_holder = Node2D.new()
		weapon_holder.name = "WeaponHolder"
		weapon_pivot.add_child(weapon_holder)
		weapon_holder.position = Vector2.ZERO
		weapon_holder.rotation = 0
		weapon_holder.scale = Vector2.ONE

	# initial state: no weapon
	has_weapon = false

# ----------------------
# MAIN LOOP
# ----------------------
func _physics_process(delta):
	if dead:
		return

	if not attacking:
		player_movement(delta)
		update_animation()   # ✅ ONLY when not attacking

	velocity += knockback_force
	knockback_force = lerp(knockback_force, Vector2.ZERO, 0.2)
	move_and_slide()

	handle_attack()
	update_layers()

func _process(delta):
	# weapon pivot and player flip are updated every frame; during attack weapon uses stored angle
	if Input.is_action_just_pressed("test_add_item"):
		print("Adding test item to inventory")
		var test_item: InvItem = preload("res://resources/pitchfork_res.tres")
		collect(test_item)
		var test_item2: InvItem = preload("res://resources/sword.tres")
		collect(test_item2)
	if Input.is_action_just_pressed("swap_weapon"):
		swap_weapons()
	if Input.is_action_just_pressed("interact") and nearby_item:
		nearby_item.collect(self)
	update_weapon_rotation()
	update_player_flip()
	sync_head_to_body()
	z_index = int(global_position.y)
	update_layers()

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

		# update horizontal and facing
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
	_update_last_dir()

# ----------------------
# HELPERS
# ----------------------
func _update_last_dir() -> void:
	# This keeps animations based on movement, not facing
	var anim_hor = hor_dir

	# If weapon changes facing_left, DON'T change direction unless player moves horizontally
	if input.x == 0:
		# keep previous left/right
		anim_hor = last_dir.split("_")[1]
	else:
		anim_hor = "left" if input.x < 0 else "right"

	# Vertical direction is still based on movement
	var anim_vert = vert_dir

	last_dir = anim_vert + "_" + anim_hor

# ----------------------
# ATTACK
# ----------------------
func handle_attack() -> void:
	if dead:
		return
	if not has_weapon or attacking:
		return

	if Input.is_action_just_pressed("attack"):
		attacking = true
		if current_weapon_scene and current_weapon_scene.has_method("start_attack"):
			current_weapon_scene.start_attack()

		input = Vector2.ZERO
		velocity = Vector2.ZERO

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

		# Rotate pivot to aim (AnimatedSprite weapons use pivot rotation; animation controls visuals)
		weapon_pivot.rotation = attack_angle if not facing_left else attack_angle + PI

		# Ensure holder exists and flip it as necessary
		if not weapon_holder and weapon_pivot:
			weapon_holder = weapon_pivot.get_node_or_null("WeaponHolder")
		if weapon_holder:
			weapon_holder.scale.x = -1 if facing_left else 1

		# Normalize inner visual scale and disable their own flip flags (we flip holder)
		var vis := weapon_sprite if weapon_sprite else weapon_anim
		if vis:
			vis.scale.x = abs(vis.scale.x)
			vis.flip_h = false

		# --- Play attack animation ---
		var played := false

		# Sword
		if sword_anim_player and sword_anim_player.has_animation("attack"):
			sword_anim_player.play("attack")
			played = true

		# Weapon scene AnimationPlayer
		elif weapon_anim_player and weapon_anim_player.has_animation("attack"):
			weapon_anim_player.play("attack")
			played = true

		# AnimatedSprite2D fallback
		if weapon_sprite and weapon_sprite.sprite_frames and weapon_sprite.sprite_frames.has_animation("attack"):
			weapon_sprite.play("attack")
			played = true

		if DEBUG:
			print("[ATTACK] Played attack:", played)

		# --- Body/head attack animations (auto-choose/flip) ---
		var suffix = "_weapon"
		var body_attack_name = "attack_" + vert_dir + "_" + hor_dir + suffix

		if body_anim and body_anim.sprite_frames:
			if not _play_with_optional_flip(body_anim, body_attack_name):
				# fallback to right version + flip if left missing
				var alt = body_attack_name.replace("_left", "_right")
				_play_with_optional_flip(body_anim, alt, true)

		if head_anim and head_anim.sprite_frames:
			if not _play_with_optional_flip(head_anim, body_attack_name):
				var alt = body_attack_name.replace("_left", "_right")
				_play_with_optional_flip(head_anim, alt, true)

# Called by AnimatedSprite2D animation_finished or body animation finished signal
func _on_attack_finished() -> void:
	# single handler for AnimatedSprite2D attack finished
	# ensure the same cleanup as the AnimationPlayer path
	attacking = false
	# force reset of pivot and holder as used by attack
	if current_weapon_scene and current_weapon_scene.has_method("end_attack"):
		current_weapon_scene.end_attack()

	if weapon_pivot:
		weapon_pivot.rotation = 0
	if weapon_holder:
		weapon_holder.scale.x = -1 if post_attack_left else 1
	# resume weapon idle/walk
	if has_weapon:
		if input == Vector2.ZERO:
			_play_weapon_anim("idle")
		else:
			_play_weapon_anim("walk")
	# resume body/head
	update_animation()
	sync_head_to_body()

# single handler connected in _ready for body anim
func _on_body_animation_finished() -> void:
	if attacking:
		# if body finished and we set attacking earlier, finalize cleanup
		_on_attack_finished()

# ----------------------
# ANIMATION (body & head & weapon idle/walk)
# ----------------------
func update_animation() -> void:
	# don't override during attack
	if attacking or not body_anim:
		return

	var suffix = ""
	if has_weapon and current_weapon_scene:
		suffix = "_weapon"

	# head visible only for down directions when weapon equipped
	var show_head = has_weapon and ("down_left" in last_dir or "down_right" in last_dir)
	if head_anim:
		head_anim.visible = show_head

	var is_idle = input == Vector2.ZERO
	var prefix = "idle_" if is_idle else "walk_"
	var base_dir = last_dir

	var full_anim = prefix + last_dir + suffix
	var frames = body_anim.sprite_frames

	# ---------------------
	# 1. PERFECT MATCH EXISTS?
	# ---------------------
	if frames.has_animation(full_anim):
		base_dir = last_dir

	else:
		# ---------------------
		# 2. LEFT VERSION MISSING → try right version + flip
		# ---------------------
		if "_left" in last_dir:
			var right_dir = last_dir.replace("_left", "_right")
			var right_anim = prefix + right_dir + suffix

			if frames.has_animation(right_anim):
				base_dir = right_dir
				body_anim.flip_h = true
			else:
				# neither left nor right weapon version exists → fallback to non-weapon animations
				base_dir = last_dir.replace("_left", "_right")
		else:
			# direction was already right
			base_dir = last_dir

	# ---------------------
	# PLAY BODY ANIMATION
	# ---------------------
	var final_anim = prefix + base_dir + suffix
	if frames.has_animation(final_anim):
		body_anim.play(final_anim)
		body_anim.flip_h = ("_left" in last_dir)  # ensure correct flip

	# ---------------------
	# HEAD ANIMATIONS
	# ---------------------
	if head_anim and head_anim.sprite_frames:
		if show_head:
			var head_anim_name = prefix + base_dir + suffix
			if head_anim.sprite_frames.has_animation(head_anim_name):
				head_anim.play(head_anim_name)
				head_anim.flip_h = ("_left" in last_dir)
		else:
			var idle_head = "idle_" + base_dir
			if head_anim.sprite_frames.has_animation(idle_head):
				head_anim.play(idle_head)
				head_anim.flip_h = ("_left" in idle_head)
			else:
				head_anim.stop()

	# ----------------------
	# WEAPON IDLE / WALK
	# ----------------------
	if has_weapon and not attacking:
		var weapon_anim := "idle" if input == Vector2.ZERO else "walk"
		_play_weapon_anim(weapon_anim)


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

	# Secondary check (defensive)
	if anim_sprite.sprite_frames.has_animation(anim_name):
		anim_sprite.play(anim_name)
		anim_sprite.flip_h = anim_name.find("_left") != -1
		return true

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
	# ensure holder is grabbed
	if not weapon_holder and weapon_pivot:
		weapon_holder = weapon_pivot.get_node_or_null("WeaponHolder")

	if not has_weapon or not weapon_pivot or not weapon_holder:
		return

	# Don't override visuals mid-attack
	if attacking:
		return

	if input != Vector2.ZERO:
		# movement updates facing
		facing_left = input.x < 0
		post_attack_left = facing_left
	else:
		# when idle keep whatever side we ended on
		facing_left = post_attack_left

	# flip holder (mirror entire weapon scene about pivot)
	weapon_holder.scale.x = -1 if facing_left else 1

	# ensure inner visuals don't double-flip
	if weapon_sprite:
		weapon_sprite.flip_h = false
	if weapon_anim:
		weapon_anim.flip_h = false

	weapon_pivot.rotation = 0

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
	if weapon_holder:
		weapon_holder.scale.x = -1 if facing_left else 1

func collect(item: InvItem, quantity: int = 1) -> void:
	var entry = InventoryEntry.new()
	entry.item = item
	entry.quantity = quantity
	inventory.add_item(entry)   # ✅ correct method

func get_inventory() -> Inv:
	return inventory

func add_to_inventory(item: InvItem, quantity: int = 1) -> bool:
	var inv_ui = get_tree().root.find_child("Inv_UI", true, false)
	if not inv_ui or not inv_ui.inv:
		print("[player] ⚠️ Inventory UI or inv not found")
		return false

	# --- Dry-run: check if there's space without adding ---
	if quantity == 0:
		for slot in inv_ui.inv.slots:
			if not slot or slot.item == null or (slot.item == item and item.stackable):
				return true
		return false

	# --- Stacking existing items ---
	for slot in inv_ui.inv.slots:
		if slot and slot.item == item and item.stackable:
			slot.amount += quantity
			inv_ui.update_slots()
			print("[player] ➕ Stacked", quantity, "x", item.name, "(now", slot.amount, ")")
			return true

	# --- Fill empty slot ---
	for slot in inv_ui.inv.slots:
		if not slot or slot.item == null:
			slot.item = item
			slot.amount = quantity
			inv_ui.update_slots()
			print("[player] ✅ Added", item.name, "x", quantity, "to inventory")
			return true

	# --- Inventory full ---
	print("[player] ⚠️ Inventory full, couldn't add", item.name)
	if inv_ui.has_method("show_message"):
		inv_ui.show_message("Inventory Full")
	else:
		print("[UI] ⚠️ Inventory Full (UI handler missing)")
	return false

# -------------------------------------------------------------------------
# EQUIP / UNEQUIP WEAPON
# -------------------------------------------------------------------------
func unequip_weapon() -> void:
	# clear current weapon
	if current_weapon_scene:
		current_weapon_scene.queue_free()
		current_weapon_scene = null
	weapon_sprite = null
	weapon_anim_player = null
	current_weapon_root = null
	weapon_grip_node = null
	has_weapon = false

	# reset pivot and holder flips
	if weapon_pivot:
		weapon_pivot.rotation = 0
	if weapon_holder:
		weapon_holder.scale = Vector2.ONE

	# update visuals immediately
	update_animation()
	sync_head_to_body()
	print("[player] Unequipped weapon")

func equip_weapon(packed_or_path) -> void:
	# ---- REMOVE OLD WEAPON ----
	if current_weapon_scene:
		current_weapon_scene.queue_free()
		current_weapon_scene = null

	has_weapon = false

	# ---- LOAD PACKED SCENE ----
	var packed: PackedScene = null

	if packed_or_path is PackedScene:
		packed = packed_or_path
	elif packed_or_path is String:
		packed = load(packed_or_path)
	elif packed_or_path is InvItem and packed_or_path.scene_path != "":
		packed = load(packed_or_path.scene_path)

	if packed == null:
		print("[player] equip_weapon: nothing equipped")
		return

	# ---- ENSURE HOLDER ----
	if not weapon_holder:
		weapon_holder = Node2D.new()
		weapon_holder.name = "WeaponHolder"
		weapon_pivot.add_child(weapon_holder)

	weapon_holder.position = Vector2.ZERO
	weapon_holder.rotation = 0
	weapon_holder.scale = Vector2.ONE

	# ---- INSTANCE WEAPON ----
	current_weapon_scene = packed.instantiate()
	weapon_holder.add_child(current_weapon_scene)

	current_weapon_scene.position = Vector2.ZERO
	current_weapon_scene.rotation = 0

	has_weapon = true

	# ---- INITIALIZE WEAPON LOGIC ----
	if current_weapon_scene.has_method("initialize"):
		current_weapon_scene.initialize(self)

	if current_weapon_scene.has_method("equip_for_owner"):
		current_weapon_scene.equip_for_owner("player")

	# ---- CACHE VISUALS ----
	weapon_sprite = _find_child_of_type(current_weapon_scene, "AnimatedSprite2D")
	weapon_anim_player = _find_child_of_type(current_weapon_scene, "AnimationPlayer")

	# ---- FORCE IDLE ----
	if weapon_sprite and weapon_sprite.sprite_frames.has_animation("idle"):
		weapon_sprite.play("idle")
		weapon_sprite.frame = 0

	if weapon_anim_player and weapon_anim_player.has_animation("idle"):
		weapon_anim_player.play("idle")

	print("[player] ✅ Equipped weapon:", current_weapon_scene.name)

func _play_weapon_anim(name: String) -> void:
	# Sword AnimationPlayer
	if sword_anim_player and sword_anim_player.has_animation(name):
		sword_anim_player.play(name)
		return

	# Weapon scene AnimationPlayer
	if weapon_anim_player and weapon_anim_player.has_animation(name):
		weapon_anim_player.play(name)
		return

	# AnimatedSprite2D (pitchfork)
	if weapon_sprite and weapon_sprite.sprite_frames and weapon_sprite.sprite_frames.has_animation(name):
		weapon_sprite.play(name)
		return

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
# Weapon AnimationPlayer finished handler
# -------------------------------------------------------------------------
func _on_weapon_animation_finished(anim_name: String) -> void:
	# only care about attack animations
	if not anim_name.begins_with("attack"):
		return

	# clear attacking state
	attacking = false
	if current_weapon_scene and current_weapon_scene.has_method("end_attack"):
		current_weapon_scene.end_attack()

	# keep facing that the attack used
	facing_left = post_attack_left

	# Reset pivot rotation
	if weapon_pivot:
		if not attacking:
			weapon_pivot.rotation = 0

	# Ensure holder flip matches final facing
	if weapon_holder:
		weapon_holder.scale.x = -1 if facing_left else 1

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

var last_equipped_scene_path: String = ""  # store the last equipped weapon’s scene path
var using_secondary: bool = false          # track which weapon is active

func swap_weapons():
	print("\n--- swap_weapons() start ---")

	var player_inv = get_tree().root.find_child("PlayerInv", true, false)
	if player_inv == null:
		push_warning("[swap_weapons] ⚠ PlayerInv not found!")
		return
	print("[swap_weapons] ✅ Using PlayerInv:", player_inv.name)

	var weapon_slot_ui: InvUISlot = player_inv.get_slot_by_type("weapon")
	var secondary_slot_ui: InvUISlot = player_inv.get_slot_by_type("secondary")

	if not weapon_slot_ui or not secondary_slot_ui:
		print("[swap_weapons] ⚠ Missing one of the slots — aborting.")
		return

	var weapon_item: InvItem = null
	var secondary_item: InvItem = null

	if weapon_slot_ui.item_stack and weapon_slot_ui.item_stack.slot:
		weapon_item = weapon_slot_ui.item_stack.slot.item
	if secondary_slot_ui.item_stack and secondary_slot_ui.item_stack.slot:
		secondary_item = secondary_slot_ui.item_stack.slot.item

	print("[swap_weapons] current_weapon:", weapon_item, " secondary:", secondary_item)

	# --- Logic ---
	if not using_secondary:
		# switching to secondary
		if not secondary_item:
			print("[swap_weapons] ⚠ No secondary weapon equipped.")
			return
		# remember current (main) weapon’s scene path
		if weapon_item and weapon_item.scene_path != "":
			last_equipped_scene_path = weapon_item.scene_path
		print("[swap_weapons] 🎯 Equipping secondary visually:", secondary_item.scene_path)
		equip_weapon(secondary_item.scene_path)
		using_secondary = true
	else:
		# switching back to main
		if last_equipped_scene_path != "":
			print("[swap_weapons] 🔁 Switching back to main:", last_equipped_scene_path)
			equip_weapon(last_equipped_scene_path)
			using_secondary = false
		else:
			print("[swap_weapons] ⚠ No previous main weapon stored.")

	print("[swap_weapons] ✅ Weapon swap complete (visual only).")
func equip_armor(scene_path: String = "") -> void:
	if scene_path == "":
		print("[Player] Unequipped armor")
		return
	var armor_scene = load(scene_path)
	if armor_scene:
		var armor_instance = armor_scene.instantiate()
		add_child(armor_instance)
		print("[Player] Equipped armor:", scene_path)
	else:
		print("[Player] ⚠ Failed to load armor from:", scene_path)

func collect_world_item(world_item) -> void:
	# Defensive checks
	if world_item == null:
		print("[Player] ⚠ collect_world_item called with null")
		return

	if not world_item.item:
		print("[Player] ⚠ world_item.item is null or missing")
		return

	var item: InvItem = world_item.item
	var qty: int = 1
	if "quantity" in world_item:
		qty = world_item.quantity

	print("[Player] 🪄 Attempting to collect:", item.name if "name" in item else item, "x", qty)

	# Attempt to add to inventory via the player's add_to_inventory (which returns bool)
	var added := false
	if has_method("add_to_inventory"):
		added = add_to_inventory(item, qty)
	else:
		print("[Player] ⚠ add_to_inventory() missing on player")

	# If added -> remove world item and update UI/resource
	if added:
		print("[Player] ✅ Collected", item.name, "x", qty)
		# update UI (if inv UI exists)
		var inv_ui := get_tree().root.find_child("Inv_UI", true, false)
		if inv_ui == null:
			inv_ui = get_tree().root.find_child("InvUI", true, false)
		if inv_ui and inv_ui.has_method("update_slots"):
			inv_ui.update_slots()
		# remove world item
		if is_instance_valid(world_item):
			world_item.queue_free()
	else:
		# inventory full -> show message and keep the world_item in the world
		print("[Player] ⚠ Inventory full, cannot pick up", item.name)
		var inv_ui := get_tree().root.find_child("Inv_UI", true, false)
		if inv_ui == null:
			inv_ui = get_tree().root.find_child("InvUI", true, false)
		if inv_ui and inv_ui.has_method("show_message"):
			inv_ui.show_message("Inventory Full")
		else:
			print("[UI] ⚠️ Inventory Full (UI handler missing)")
func external_knockback(force: Vector2, damage: int = 1) -> void:
	knockback_force = force
	_debug_camera_lookup("Player took hit")

	var cam := get_viewport().get_camera_2d()
	if cam:
		cam.shake(6.0, 0.15)

	decrease_lives(damage)

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

func decrease_lives(damage: int = 1) -> void:
	if dead or default_lives <= 0 or damage <= 0:
		return

	var lives_to_remove = min(damage, default_lives)

	for i in range(lives_to_remove):
		default_lives -= 1
		emit_signal("life_lost", default_lives)
		emit_signal("lives_changed", default_lives)

		if default_lives <= 0:
			default_lives = 0
			dead = true
			emit_signal("player_died")
			return

func _on_life_lost(current_lives: int) -> void:
	# purely optional here — usually UI handles effects
	print("[Player] ❤️ Life lost, remaining:", current_lives)

func _on_player_died() -> void:
	print("[Player] ☠ Player died")

	dead = true
	attacking = false
	input = Vector2.ZERO
	velocity = Vector2.ZERO

	# stop weapon visuals
	if weapon_anim_player:
		weapon_anim_player.stop()
	if weapon_sprite:
		weapon_sprite.stop()

	# play player death animation
	if $AnimationPlayer and $AnimationPlayer.has_animation("death"):
		$AnimationPlayer.play("death")

	# disable movement, play animation, etc.
func apply_damage(damage: int = 1) -> void:
	decrease_lives(damage)
