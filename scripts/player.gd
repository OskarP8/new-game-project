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
# ----------------------
# NODES
# ----------------------
@onready var body_anim := $Graphics/Body as AnimatedSprite2D
@onready var head_anim := $Graphics/Head as AnimatedSprite2D
@onready var weapon_pivot := $Graphics/WeaponPivot as Node2D
@onready var weapon_anim := $Graphics/WeaponPivot/Weapon as AnimatedSprite2D
# sword_anim_player node reference kept in case it exists in tree
@onready var sword_anim_player := $Graphics/WeaponPivot/Sword/AnimationPlayer

func _dummy_set(v): pass

# ----------------------
# READY
# ----------------------
func _ready() -> void:
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
		if weapon_anim_player:
			# prefer AnimationPlayer if present
			if weapon_anim_player.has_animation("attack"):
				weapon_anim_player.play("attack")
		else:
			# fallback to AnimatedSprite2D animations
			var vis_weapon := weapon_sprite if weapon_sprite else weapon_anim
			if vis_weapon and vis_weapon.sprite_frames:
				# prefer unified "attack" frame animation, else directional ones
				if vis_weapon.sprite_frames.has_animation("attack"):
					vis_weapon.play("attack")
					if not vis_weapon.is_connected("animation_finished", Callable(self, "_on_attack_finished")):
						vis_weapon.animation_finished.connect(Callable(self, "_on_attack_finished"))
				else:
					var wanim := "attack_left" if facing_left else "attack_right"
					if vis_weapon.sprite_frames.has_animation(wanim):
						vis_weapon.play(wanim)
						if not vis_weapon.is_connected("animation_finished", Callable(self, "_on_attack_finished")):
							vis_weapon.animation_finished.connect(Callable(self, "_on_attack_finished"))

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
	# don't override while performing an attack
	if attacking or not body_anim:
		return

	# --- Setup ---
	var suffix = ""
	if has_weapon and current_weapon_scene:
		suffix = "_weapon"

	# show_head only when weapon equipped and look is 'down'
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
	if head_anim and head_anim.sprite_frames:
		if show_head:
			_play_with_optional_flip(head_anim, anim_name)
		else:
			# head should return to non-weapon idle or stop
			var idle_head = "idle_" + base_dir
			if head_anim.sprite_frames.has_animation(idle_head):
				# prefer non-weapon idle version (no suffix)
				head_anim.play(idle_head)
				head_anim.flip_h = idle_head.find("_left") != -1
			else:
				# no suitable idle -> stop playback to avoid leftover attack loop
				head_anim.stop()

	# --- WEAPON ANIMATION ---
	if has_weapon and (weapon_anim or weapon_sprite):
		var vis := weapon_sprite if weapon_sprite else weapon_anim
		var weapon_anim_name = "idle" if is_idle else "walk"
		if vis and vis.sprite_frames and vis.sprite_frames.has_animation(weapon_anim_name):
			vis.play(weapon_anim_name)
	else:
		# ensure any leftover weapon visuals stop when unequipped
		if weapon_anim:
			weapon_anim.stop()
		if weapon_sprite:
			weapon_sprite.stop()

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

func add_to_inventory(item: InvItem, quantity: int = 1):
	var inv_ui = get_tree().root.find_child("InvUI", true, false)
	if inv_ui and inv_ui.inv:
		for slot in inv_ui.inv.slots:
			if slot.item == null:
				slot.item = item
				slot.amount = quantity
				inv_ui.update_slots()
				print("[player] ✅ Added", item.name, "x", quantity, "to inventory")
				return
	print("[player] ⚠️ Inventory full, couldn't add", item.name)

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
	# Remove old weapon first (use unequip to keep behavior consistent)
	unequip_weapon()
	if packed_or_path == null or packed_or_path == "":
		# Unequip
		if current_weapon_scene:
			current_weapon_scene.queue_free()
		current_weapon_scene = null
		has_weapon = false
		print("[player] Weapon unequipped")
		return
	# Load: accept string path, PackedScene, or InvItem with scene_path
	var packed = null
	if typeof(packed_or_path) == TYPE_STRING:
		packed = load(packed_or_path)
	elif packed_or_path is PackedScene:
		packed = packed_or_path
	elif packed_or_path is InvItem:
		if "scene_path" in packed_or_path and packed_or_path.scene_path != "":
			packed = load(packed_or_path.scene_path)
		else:
			push_warning("equip_weapon: InvItem has no valid scene_path")
			return
	else:
		push_warning("equip_weapon: invalid argument type")
		return

	if not (packed is PackedScene):
		push_warning("equip_weapon: loaded resource is not a PackedScene -> " + str(packed))
		return

	# Ensure holder exists and assign to weapon_holder
	if not weapon_holder and weapon_pivot:
		weapon_holder = weapon_pivot.get_node_or_null("WeaponHolder")
		if not weapon_holder:
			weapon_holder = Node2D.new()
			weapon_holder.name = "WeaponHolder"
			weapon_pivot.add_child(weapon_holder)
	weapon_holder.position = Vector2.ZERO
	weapon_holder.rotation = 0
	weapon_holder.scale.x = -1 if facing_left else 1

	# Instantiate scene under holder
	current_weapon_scene = packed.instantiate()
	weapon_holder.add_child(current_weapon_scene)
	current_weapon_scene.position = Vector2.ZERO
	current_weapon_scene.rotation = 0
	current_weapon_root = current_weapon_scene

	# find visuals
	weapon_sprite = _find_child_of_type(current_weapon_scene, "AnimatedSprite2D")
	weapon_anim_player = _find_child_of_type(current_weapon_scene, "AnimationPlayer")

	# store base scale for consistent flipping (magnitude only)
	if weapon_sprite:
		weapon_sprite_base_scale_x = abs(weapon_sprite.scale.x) if weapon_sprite.scale.x != 0 else 1.0
	else:
		weapon_sprite_base_scale_x = 1.0

	# connect animation finished if AnimationPlayer used
	if weapon_anim_player:
		if weapon_anim_player.is_connected("animation_finished", Callable(self, "_on_weapon_animation_finished")):
			weapon_anim_player.disconnect("animation_finished", Callable(self, "_on_weapon_animation_finished"))
		weapon_anim_player.animation_finished.connect(Callable(self, "_on_weapon_animation_finished"))

	# when using AnimatedSprite2D we may need its animation_finished too (connect on demand)
	if weapon_sprite:
		if not weapon_sprite.is_connected("animation_finished", Callable(self, "_on_attack_finished")):
			weapon_sprite.animation_finished.connect(Callable(self, "_on_attack_finished"))

	has_weapon = current_weapon_scene != null
	print("[player] equip_weapon -> scene:", packed, " sprite:", weapon_sprite, " anim_player:", weapon_anim_player, " holder.scale.x:", weapon_holder.scale.x)

	# Force animation update so head/body switch to weapon variants
	update_animation()
	sync_head_to_body()

# helper to play either AnimationPlayer or AnimatedSprite2D animation
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
# Weapon AnimationPlayer finished handler
# -------------------------------------------------------------------------
func _on_weapon_animation_finished(anim_name: String) -> void:
	# only care about attack animations
	if not anim_name.begins_with("attack"):
		return

	# clear attacking state
	attacking = false

	# keep facing that the attack used
	facing_left = post_attack_left

	# Reset pivot rotation
	if weapon_pivot:
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

	# Access exported properties directly (WorldItem exports `item` and `quantity`)
	if not world_item.item:
		print("[Player] ⚠ world_item.item is null or missing")
		return

	var item: InvItem = world_item.item
	var qty: int = 1
	if "quantity" in world_item:
		# direct access — WorldItem should export quantity
		qty = world_item.quantity

	print("[Player] 🪄 Collecting world item:", item.name if "name" in item else item, "x", qty)

	# Ensure we have an inventory resource to add to
	if inventory == null:
		print("[Player] ⚠ inventory resource is null — cannot add item")
	else:
		# Inventory.add_item expects an InventoryEntry resource
		var entry = InventoryEntry.new()
		entry.item = item
		entry.quantity = qty
		inventory.add_item(entry)
		print("[Player] ✅ Added to inventory via resource")

	# If you also want to update the UI immediately (optional)
	var inv_ui = get_tree().root.find_child("Inv_UI", true, false)
	if inv_ui == null:
		inv_ui = get_tree().root.find_child("InvUI", true, false)
	if inv_ui and inv_ui.has_method("update_slots"):
		inv_ui.update_slots()
		print("[Player] ✅ Inv UI update requested")
	else:
		print("[Player] ⚠ Inv UI not found or missing update_slots")

	# Finally remove the world item from the scene
	world_item.queue_free()
	print("[Player] 🗑 world_item queued for free")
