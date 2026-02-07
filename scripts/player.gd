extends CharacterBody2D

signal lives_changed(current_lives: int)
signal life_lost(current_lives: int)
signal player_died
signal player_dying_started

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
var weapon_instances := {}  # scene_path -> Node

var nearby_item: WorldItem = null
var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_time: float = 0.0
var default_lives = 5
var dead: bool = false
var invincible := false
var invincible_time := 0.18
var dying := false
# ----------------------
# KNOCKBACK (PLAYER)
# ----------------------
var is_in_knockback := false
var knockback_timer := 0.0

var suppress_weapon_rotation_frame := false
var suppress_body_anim_frame := false
# reentrancy guard to prevent infinite recursion between UI <-> player updates
var _refresh_inventory_lock := false

# ----------------------
# NODES
# ----------------------
@onready var body_anim := $Graphics/Body as AnimatedSprite2D
@onready var head_anim := $Head as AnimatedSprite2D
@onready var weapon_pivot_back := $Graphics/WeaponPivotBack/WeaponPivot
@onready var weapon_pivot_front := $Graphics/WeaponPivotFront/WeaponPivot
var weapon_pivot: Node2D

@onready var weapon_anim := $Graphics/WeaponPivot/Weapon as AnimatedSprite2D

@onready var lives: CanvasLayer = $Lives

func _dummy_set(v): pass

# Safe root/node lookup helpers ------------------------------------------------
func _get_root() -> Node:
	var t = get_tree()
	if t == null:
		return null
	# in some shutdown orders tree.root can be null
	return t.root if t.root != null else null

func _find_root_child(name: String, recursive: bool=true, owned: bool=false) -> Node:
	var root = _get_root()
	if root == null:
		return null
	return root.find_child(name, recursive, owned)

# ----------------------
# READY
# ----------------------
func _ready():
	# your existing initialization...
	if has_node("/root/GameState"):
		var gs = get_node("/root/GameState")
		# call restore to populate player inventory from last save
		if gs.has_method("restore_inventory_to_player"):
			gs.restore_inventory_to_player(self)

	# --- RESPAWN POSITION ---
	# (replace your existing checkpoint/save block with the following)
	if GameState.has_checkpoint():
		# checkpoint_position should already be a Vector2
		global_position = GameState.checkpoint_position
	elif GameState.has_save():
		var data = GameState.get_save_data()
		# defensive conversion: data.position may be a Vector2 or a Dictionary {"x","y"}
		var pos: Vector2 = Vector2.ZERO
		if typeof(data.position) == TYPE_VECTOR2:
			pos = data.position
		elif typeof(data.position) == TYPE_DICTIONARY:
			var p = data.position
			pos = Vector2(p.get("x", 0.0), p.get("y", 0.0))
		else:
			# fallback: if GameState returned something unexpected, keep origin
			pos = Vector2.ZERO

		global_position = pos

	var cam := get_viewport().get_camera_2d()
	if cam:
		cam.reset_smoothing()
	var player_inv = get_tree().root.find_child("PlayerInv", true, false)

	if player_inv and player_inv.has_signal("inventory_changed"):
		player_inv.inventory_changed.connect(Callable(self, "refresh_equipped_weapon_from_inventory"))
		# autosave on inventory change:
		if has_node("/root/GameState"):
			var gs := get_node("/root/GameState")
			if gs and gs.has_method("save"):
				# connect an autosave callable on the UI (avoid double connections)
				var save_callable := Callable(gs, "save")
				# Godot's is_connected requires a target object + method name; using Callable for checking is cleaner:
				var already_connected := false
				for conn in player_inv.get_signal_connection_list("inventory_changed"):
					# each conn is a dictionary with "target" and "method"
					if conn.target == gs and conn.method == "save":
						already_connected = true
						break
				if not already_connected:
					player_inv.inventory_changed.connect(save_callable)
	print("[PLAYER DEBUG] player.inventory resource:", inventory, " resource_path:", (inventory.resource_path if inventory else "NULL"), "slots:", (inventory.slots.size() if inventory and 'slots' in inventory else "NO_SLOTS"))
	if inventory and "slots" in inventory:
		for i in range(min(32, inventory.slots.size())):
			var s = inventory.slots[i]
			print("  [player.inv.slot %d] item=%s amount=%s" % [i, (s.item if s else "NULL"), (s.amount if s and 'amount' in s else "NULL")])

	has_weapon = false

	if last_equipped_scene_path != "":
		equip_weapon(last_equipped_scene_path)

	weapon_pivot = weapon_pivot_front
	weapon_holder = weapon_pivot.get_node_or_null("WeaponHolder")
	if not weapon_holder:
		weapon_holder = Node2D.new()
		weapon_holder.name = "WeaponHolder"
		weapon_pivot.add_child(weapon_holder)
		weapon_holder.position = Vector2.ZERO
		weapon_holder.rotation = 0
		weapon_holder.scale = Vector2.ONE

	body_anim.z_index = 0
	head_anim.z_index = 0
	weapon_pivot.z_index = 0

	life_lost.connect(_on_life_lost)
	player_died.connect(_on_player_died)

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
	# DEBUG: sanity at end of _ready
	print("[player][DBG READY] _ready() finished. last_equipped_scene_path:", last_equipped_scene_path, " weapon_pivot:", weapon_pivot, " weapon_holder:", weapon_holder)
	var _inv_ui = get_tree().root.find_child("Inv_UI", true, false)
	print("[player][DBG READY] Inv_UI found ->", _inv_ui, " Player in groups ->", get_tree().get_first_node_in_group("Player"))

	# initial state: no weapon
	has_weapon = false
	refresh_equipped_weapon_from_inventory()

# ----------------------
# MAIN LOOP
# ----------------------
func _physics_process(delta):
	if dead or dying:
		return

	if knockback_time > 0.0:
		knockback_time -= delta
		velocity = knockback_velocity
		move_and_slide()
		return

	if not attacking:
		player_movement(delta)
		update_animation()   # ✅ ONLY when not attacking

	move_and_slide()

	handle_attack()
	update_layers()

func _process(delta):
	if dead or dying:
		return
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
	update_layers()
	if suppress_weapon_rotation_frame:
		suppress_weapon_rotation_frame = false

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

		# Weapon scene AnimationPlayer
		if weapon_anim_player and weapon_anim_player.has_animation("attack"):
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
	suppress_weapon_rotation_frame = true

	attacking = false
	suppress_body_anim_frame = true

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
	if dead or dying:
		return
	# don't override during attack
	if suppress_body_anim_frame:
		suppress_body_anim_frame = false
		return

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
	if not weapon_pivot:
		return

	var target_parent: Node

	if vert_dir == "up":
		target_parent = $Graphics/WeaponPivotBack
	else:
		target_parent = $Graphics/WeaponPivotFront

	if weapon_pivot.get_parent() != target_parent:
		weapon_pivot.reparent(target_parent)
		weapon_pivot.position = Vector2.ZERO
		weapon_holder = weapon_pivot.get_node("WeaponHolder")

# ----------------------
# HEAD SYNC
# ----------------------
func sync_head_to_body() -> void:
	if dead or dying:
		return

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
	if dead or dying:
		return
	# ensure holder is grabbed
	if attacking:
		return

	if suppress_weapon_rotation_frame:
		suppress_weapon_rotation_frame = false
		return

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
	if dead or dying:
		return
	# Flip body and head visually based on facing_left
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

			# 🔁 MIRROR UI INVENTORY → PLAYER INVENTORY
			if inventory and "slots" in inventory:
				inventory.slots.clear()
				for ui_slot in inv_ui.inv.slots:
					var new_slot := InvSlot.new()
					new_slot.item = ui_slot.item
					new_slot.amount = ui_slot.amount
					inventory.slots.append(new_slot)

			print("[player] ➕ Stacked", quantity, "x", item.name, "(now", slot.amount, ")")
			if has_node("/root/GameState"):
				get_node("/root/GameState").save()
			return true

	# --- Fill empty slot ---
	for slot in inv_ui.inv.slots:
		if not slot or slot.item == null:
			slot.item = item
			slot.amount = quantity
			inv_ui.update_slots()

			# 🔁 MIRROR UI INVENTORY → PLAYER INVENTORY
			if inventory and "slots" in inventory:
				inventory.slots.clear()
				for ui_slot in inv_ui.inv.slots:
					var new_slot := InvSlot.new()
					new_slot.item = ui_slot.item
					new_slot.amount = ui_slot.amount
					inventory.slots.append(new_slot)

			print("[player] ✅ Added", item.name, "x", quantity, "to inventory")
			if has_node("/root/GameState"):
				get_node("/root/GameState").save()
			return true

	# --- Inventory full ---
	print("[player] ⚠️ Inventory full, couldn't add", item.name)
	if inv_ui.has_method("show_message"):
		inv_ui.show_message("Inventory Full")
	else:
		print("[UI] ⚠️ Inventory Full (UI handler missing)")
	return false

# returns Array of plain dicts {"scene_path": "...", "amount": N}
func get_inventory_snapshot() -> Array:
	# If `inventory` is your Inv resource with .slots array, convert to plain dicts.
	var out := []
	if inventory and "slots" in inventory:
		for s in inventory.slots:
			if s == null or s.item == null:
				out.append({"scene_path":"", "amount":0})
				continue
			var item_obj = s.item
			var item_path := ""
			if "id" in item_obj and str(item_obj.id) != "":
				item_path = "id:" + str(item_obj.id)
			elif "resource_path" in item_obj and str(item_obj.resource_path) != "":
				item_path = str(item_obj.resource_path)
			elif "scene_path" in item_obj and str(item_obj.scene_path) != "":
				item_path = str(item_obj.scene_path)
			elif "name" in item_obj:
				item_path = "name:" + str(item_obj.name)
			else:
				item_path = "unknown"
			out.append({"scene_path": item_path, "amount": int(s.amount if "amount" in s else 1)})
	# If no resource, attempt to synthesize from player_inv UI (best-effort)
	else:
		var player_inv = get_tree().root.find_child("PlayerInv", true, false)
		if player_inv and player_inv.inv and "slots" in player_inv.inv:
			for s in player_inv.inv.slots:
				if s == null or s.item == null:
					out.append({"scene_path":"", "amount":0})
					continue
				var item_obj = s.item
				var item_path := ""
				if "id" in item_obj and str(item_obj.id) != "":
					item_path = "id:" + str(item_obj.id)
				elif "resource_path" in item_obj and str(item_obj.resource_path) != "":
					item_path = str(item_obj.resource_path)
				elif "scene_path" in item_obj and str(item_obj.scene_path) != "":
					item_path = str(item_obj.scene_path)
				elif "name" in item_obj:
					item_path = "name:" + str(item_obj.name)
				else:
					item_path = "unknown"
				out.append({"scene_path": item_path, "amount": int(s.amount if "amount" in s else 1)})

	print("[PLAYER DEBUG] returning snapshot from player.inventory (len):", (inventory.slots.size() if inventory and 'slots' in inventory else 0))
	var tmp = []
	if inventory and 'slots' in inventory:
		for i in range(inventory.slots.size()):
			var s = inventory.slots[i]
			tmp.append({
				"i": i,
				"item": (s.item if s and 'item' in s else null),
				"amount": (s.amount if s and 'amount' in s else 0)
			})
	print("[PLAYER DEBUG] snapshot detail (first 32):")
	for i in range(min(32, tmp.size())):
		print("  ", tmp[i])
	return out

# returns the authoritative number of player inventory slots (e.g., 4)
func get_inventory_slot_count() -> int:
	# Prefer the inventory resource length if present
	if inventory and "slots" in inventory:
		return inventory.slots.size()
	# Fallback to PlayerInv UI if present
	var player_inv = get_tree().root.find_child("PlayerInv", true, false)
	if player_inv and "slots" in player_inv:
		return player_inv.slots.size()
	# Last resort: return 4 (sensible default for your project)
	return 4

# Accepts plain snapshot array of dicts and writes into player's authoritative Inv resource
func set_inventory_from_snapshot(arr: Array) -> void:
	# Defensive verbose version to help debug why items become null during restore.
	print("[player] set_inventory_from_snapshot: start; entries:", arr.size())

	# Ensure inventory resource exists
	if not inventory:
		print("[player] set_inventory_from_snapshot: inventory resource missing; creating new Inv resource")
		inventory = preload("res://inventory/inv.tres").duplicate(true)

	# Resize inventory.slots and populate
	if "slots" in inventory:
		inventory.slots.clear()
		for i in range(arr.size()):
			var entry = arr[i]
			var new_slot := InvSlot.new()
			new_slot.amount = int(entry.get("amount", 0))
			new_slot.item = null

			var raw_sp := str(entry.get("scene_path", "")).strip_edges()
			var sp := raw_sp
			if sp == "":
				print("\t[slot %d] scene_path empty -> leaving item null, amount=%d" % [i, new_slot.amount])
				inventory.slots.append(new_slot)
				continue

			# If starts with "id:", extract id safely
			if sp.begins_with("id:"):
				var id_str := ""
				# extract substring after "id:" cleanly
				if sp.length() > 3:
					id_str = sp.substr(3, sp.length() - 3)
				else:
					id_str = ""
				print("\t[slot %d] resolving id -> '%s' (raw='%s')" % [i, id_str, sp])

				# 1) Player-local finder (method on player)
				var found = null
				if has_method("_find_invitem_by_id"):
					found = _find_invitem_by_id(id_str)
					if found:
						print("\t\tresolved via player._find_invitem_by_id ->", found)
				# 2) GameState helper finder
				if not found and has_node("/root/GameState"):
					var gs = get_node("/root/GameState")
					if gs and gs.has_method("find_invitem_by_id"):
						found = gs.find_invitem_by_id(id_str)
						if found:
							print("\t\tresolved via GameState.find_invitem_by_id ->", found)
				# 3) Try scanning GameState.registry as fallback
				if not found and has_node("/root/GameState"):
					var gs2 = get_node("/root/GameState")
					if gs2 and "registry" in gs2 and gs2.registry:
						for reg in gs2.registry:
							if typeof(reg) == TYPE_OBJECT and reg != null and "id" in reg and str(reg.id) == id_str:
								found = reg
								print("\t\tresolved via GameState.registry resource ->", found)
								break
							elif typeof(reg) == TYPE_STRING:
								if ResourceLoader.exists(reg):
									var rtest = ResourceLoader.load(reg)
									if rtest and "id" in rtest and str(rtest.id) == id_str:
										found = rtest
										print("\t\tresolved via GameState.registry path ->", reg)
										break

				if found:
					new_slot.item = found
					inventory.slots.append(new_slot)
					continue

				# Nothing found for id:
				print("\t\t[slot %d] WARNING: could not resolve id '%s' -> leaving null" % [i, id_str])
				inventory.slots.append(new_slot)
				continue

			# If not id: try loading as resource path
			if sp != "":
				print("\t[slot %d] trying resource path -> '%s'" % [i, sp])
				# ResourceLoader expects a path like "res://...." — guard and attempt load
				if ResourceLoader.exists(sp):
					var loaded := ResourceLoader.load(sp)
					if loaded:
						new_slot.item = loaded
						print("\t\tloaded resource ->", sp)
					else:
						print("\t\tResourceLoader.load returned null for", sp)
				else:
					print("\t\tResourceLoader.exists false for", sp, "- not a path I can load")
				inventory.slots.append(new_slot)
				continue

			# fallback: unrecognized scene_path string
			print("\t[slot %d] Unrecognized scene_path format: '%s' -> leaving null" % [i, raw_sp])
			inventory.slots.append(new_slot)
	else:
		print("[player] set_inventory_from_snapshot: inventory resource does not have slots member")
		return

	# apply refresh locally (use our helper)
	_refresh_after_inventory_change()
	print("[player] set_inventory_from_snapshot: finished; inventory.slots:", inventory.slots.size())
	for j in range(min(16, inventory.slots.size())):
		var cs = inventory.slots[j]
		print("\t[post %d] item:%s amount:%s" % [j, (cs.item if cs else "NULL"), (cs.amount if cs and 'amount' in cs else "NULL")])

# -------------------------------------------------------------------------
# EQUIP / UNEQUIP WEAPON
# -------------------------------------------------------------------------
func unequip_weapon() -> void:
	# Respect any UI-supplied suppression flag to avoid race conditions
	var suppressed = has_meta("suppress_unequip") and get_meta("suppress_unequip") == true
	print("[player][DBG unequip] called; suppress_unequip? ->", suppressed, " current_weapon_scene:", current_weapon_scene, " has_weapon:", has_weapon)

	if suppressed:
		# Don't actually unequip while suppression active — just log and return
		print("[player][DBG unequip] suppressed => skipping actual unequip")
		return

	# clear current weapon (hide, don't free)
	if current_weapon_scene:
		current_weapon_scene.visible = false
		current_weapon_scene = null

	weapon_sprite = null
	weapon_anim_player = null
	current_weapon_root = null
	weapon_grip_node = null
	has_weapon = false

	# reset pivot and holder transforms
	if weapon_pivot:
		weapon_pivot.rotation = 0
	if weapon_holder:
		weapon_holder.scale = Vector2.ONE

	# update visuals immediately
	update_animation()
	sync_head_to_body()
	print("[player] Unequipped weapon")

func equip_weapon(packed_or_path) -> void:
	print("[player][DBG equip_weapon ENTRY] arg:", packed_or_path, " typeof:", typeof(packed_or_path))

	# ---- HIDE OLD WEAPON (DO NOT FREE) ----
	if is_instance_valid(current_weapon_scene):
		current_weapon_scene.visible = false
	# --- REPLACE the small problematic chunk at the top of equip_weapon() with this ---

	print("[player][DBG] equip_weapon called; arg type:", typeof(packed_or_path), "arg:", packed_or_path)
# existing first lines follow...


	# hide old weapon if it's still alive (don't free it; just hide)
	if is_instance_valid(current_weapon_scene):
		current_weapon_scene.visible = false

	# NOTE: do NOT null-out current_weapon_scene/has_weapon here.
	# We'll assign them only after we successfully instantiate/load the new scene.

	# ---- LOAD PACKED SCENE ----
	var packed: PackedScene = null

	if packed_or_path is PackedScene:
		packed = packed_or_path
	elif packed_or_path is String and packed_or_path != "":
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
	var scene_path := packed.resource_path

	if weapon_instances.has(scene_path) and is_instance_valid(weapon_instances[scene_path]):
		current_weapon_scene = weapon_instances[scene_path]
		if not current_weapon_scene.get_parent():
			weapon_holder.add_child(current_weapon_scene)
	else:
		current_weapon_scene = packed.instantiate()
		weapon_instances[scene_path] = current_weapon_scene
		weapon_holder.add_child(current_weapon_scene)

	current_weapon_scene.visible = true
	has_weapon = true
	# store for persistence / debugging
	if scene_path != null and scene_path != "":
		last_equipped_scene_path = scene_path

	# ---- REFRESH CACHED VISUAL REFERENCES ----
	weapon_sprite = _find_child_of_type(current_weapon_scene, "AnimatedSprite2D")
	weapon_anim_player = _find_child_of_type(current_weapon_scene, "AnimationPlayer")

	current_weapon_scene.position = Vector2.ZERO
	current_weapon_scene.rotation = 0

	# --- Now print debug info reflecting final state (safe) ---
	print("[player][DBG] equip_weapon: current_weapon_scene =", current_weapon_scene, "visible? ->", (current_weapon_scene.visible if current_weapon_scene else "NULL"))
	print("[player][DBG] equip_weapon: has_weapon flag ->", has_weapon)

	# ---- ALIGN WEAPON TO GRIP ----
	weapon_grip_node = _find_child_named(current_weapon_scene, "Grip")

	if weapon_grip_node:
		# Move weapon so Grip sits on pivot origin
		current_weapon_scene.position = -weapon_grip_node.position
	else:
		push_warning("[Weapon] Grip node not found in weapon scene")

	# ---- INITIALIZE WEAPON LOGIC ----
	current_weapon_scene.initialize(
		self,
		weapon_pivot,
		weapon_holder
	)

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
	print("[player][DBG] equip_weapon finished -> current_weapon_scene:", current_weapon_scene, "has_weapon:", has_weapon, "parent:", (current_weapon_scene.get_parent() if current_weapon_scene and is_instance_valid(current_weapon_scene) else "NULL"))

	print("[player] ✅ Equipped weapon:", current_weapon_scene.name)
	update_layers()
	update_weapon_rotation()

func _play_weapon_anim(name: String) -> void:
	# Weapon scene AnimationPlayer
	if is_instance_valid(weapon_anim_player):
		if weapon_anim_player.has_animation(name):
			weapon_anim_player.play(name)
			return
	else:
		weapon_anim_player = null

	# AnimatedSprite2D fallback
	if is_instance_valid(weapon_sprite):
		if weapon_sprite.sprite_frames and weapon_sprite.sprite_frames.has_animation(name):
			weapon_sprite.play(name)
			return
	else:
		weapon_sprite = null

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
	if not player_inv:
		push_warning("[swap_weapons] PlayerInv not found")
		return

	var weapon_slot_ui: InvUISlot = player_inv.get_slot_by_type("weapon")
	var secondary_slot_ui: InvUISlot = player_inv.get_slot_by_type("secondary")

	if not weapon_slot_ui or not secondary_slot_ui:
		print("[swap_weapons] Missing weapon slots")
		return

	var weapon_item: InvItem = null
	var secondary_item: InvItem = null

	if weapon_slot_ui.item_stack and weapon_slot_ui.item_stack.slot:
		weapon_item = weapon_slot_ui.item_stack.slot.item
	if secondary_slot_ui.item_stack and secondary_slot_ui.item_stack.slot:
		secondary_item = secondary_slot_ui.item_stack.slot.item

	print("[swap_weapons] weapon:", weapon_item, "secondary:", secondary_item)

	# Decide based on current state
	if not using_secondary:
		if not secondary_item:
			print("[swap_weapons] No secondary weapon")
			return
		equip_weapon(secondary_item.scene_path)
		using_secondary = true
	else:
		if not weapon_item:
			print("[swap_weapons] No primary weapon")
			return
		equip_weapon(weapon_item.scene_path)
		using_secondary = false

	print("[swap_weapons] Swap complete")

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
	if is_instance_valid(world_item):
		world_item.queue_free()

	# NEW: autosave immediately after successful pickup
	if has_node("/root/GameState"):
		get_node("/root/GameState").save()

func external_knockback(source_pos: Vector2, strength: float, damage: int = 1, duration: float = 0.25) -> void:
	print("PLAYER external_knockback CALLED", strength)

	#if dead or invincible:
		#return

	invincible = true

	var dir := global_position - source_pos
	if dir.length() == 0:
		dir = Vector2.RIGHT

	var velocity_mag := strength / duration
	knockback_velocity = dir.normalized() * velocity_mag
	knockback_time = duration

	var cam := get_viewport().get_camera_2d()
	if cam:
		cam.shake(6.0, 0.15)

	apply_damage(damage)

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
	if dead or dying:
		return

	for i in range(damage):
		if default_lives <= 0:
			break
		default_lives -= 1
		emit_signal("life_lost", default_lives)
		emit_signal("lives_changed", default_lives)

	# ✅ only trigger once, and DO NOT kill immediately
	if default_lives <= 0:
		await _last_leaf_sequence()
		_start_death_sequence()

func _on_life_lost(current_lives: int) -> void:
	# purely optional here — usually UI handles effects
	print("[Player] ❤️ Life lost, remaining:", current_lives)

func _on_player_died() -> void:
	print("[Player] ☠ Player died")

	attacking = false
	input = Vector2.ZERO
	velocity = Vector2.ZERO

	# stop weapon visuals
	if weapon_anim_player:
		weapon_anim_player.stop()
	if weapon_sprite:
		weapon_sprite.stop()

func apply_damage(damage: int = 1) -> void:
	if dead or invincible or default_lives <= 0:
		return

	invincible = true
	decrease_lives(damage)

	await get_tree().create_timer(invincible_time).timeout
	invincible = false

func _die() -> void:
	if dead:
		return

	dead = true
	emit_signal("player_died")

	# 🔴 UNEQUIP WEAPON FIRST
	unequip_weapon()
	# hide separate head (death body already has one)
	if head_anim:
		head_anim.visible = false

	velocity = Vector2.ZERO
	attacking = false

	if $CollisionShape2D:
		$CollisionShape2D.disabled = true

func check_death():
	if dead:
		return

	if default_lives <= 0:
		await _last_leaf_sequence()
		_start_death_sequence()

func _start_death_sequence():
	if dead or dying:
		return

	dying = true
	_die()

func _last_leaf_sequence() -> void:
	if dying:
		return

	emit_signal("player_dying_started")

	# wait for leaf animation (scaled time)
	await get_tree().create_timer(0.6, true).timeout

	# impact shake when leaf dies
	var cam := get_viewport().get_camera_2d()
	if cam:
		cam.shake(12.0, 0.4)

	# emotional beat (real time)
	await get_tree().create_timer(0.12).timeout

func refresh_equipped_weapon_from_inventory():
	# Avoid racing with UI flows that temporarily clear visuals
	if has_meta("suppress_unequip") and get_meta("suppress_unequip") == true:
		print("[player][DBG refresh] suppressed by meta -> skipping refresh_equipped_weapon_from_inventory")
		return

	var player_inv = _find_root_child("PlayerInv", true, false)
	if not player_inv:
		print("[player][DBG refresh] PlayerInv not found -> skipping")
		return

	# Find the UI slots (InvUISlot nodes)
	var weapon_slot_ui: InvUISlot = player_inv.get_slot_by_type("weapon")
	var secondary_slot_ui: InvUISlot = player_inv.get_slot_by_type("secondary")

	# Try to read the underlying Inv resource (authoritative) first
	var weapon_item = null
	var secondary_item = null

	# If player_inv.inv exists, try to locate corresponding resource slots by index
	if player_inv.inv:
		# locate indices of UI slots in the player_inv.slots array
		if weapon_slot_ui:
			var widx = player_inv.slots.find(weapon_slot_ui)
			if widx != -1 and player_inv.inv.slots.size() > widx:
				weapon_item = player_inv.inv.slots[widx].item
		if secondary_slot_ui:
			var sidx = player_inv.slots.find(secondary_slot_ui)
			if sidx != -1 and player_inv.inv.slots.size() > sidx:
				secondary_item = player_inv.inv.slots[sidx].item

	# Fallback: if resource read failed, try UI visual chain (older behaviour)
	if weapon_item == null and weapon_slot_ui and weapon_slot_ui.item_stack and weapon_slot_ui.item_stack.slot:
		weapon_item = weapon_slot_ui.item_stack.slot.item
	if secondary_item == null and secondary_slot_ui and secondary_slot_ui.item_stack and secondary_slot_ui.item_stack.slot:
		secondary_item = secondary_slot_ui.item_stack.slot.item

	print("[player][DBG refresh] using_secondary:", using_secondary,
		" weapon_item:", (weapon_item if weapon_item else "NULL"),
		" secondary_item:", (secondary_item if secondary_item else "NULL"))

	# Apply logic (same as before)
	if using_secondary:
		if secondary_item:
			equip_weapon(secondary_item.scene_path)
		elif weapon_item:
			using_secondary = false
			equip_weapon(weapon_item.scene_path)
		else:
			using_secondary = false
			unequip_weapon()
	else:
		if weapon_item:
			equip_weapon(weapon_item.scene_path)
		elif secondary_item:
			using_secondary = true
			equip_weapon(secondary_item.scene_path)
		else:
			unequip_weapon()

# Try to resolve an InvItem/resource by an "id" string like "001".
# Uses GameState registry if present, then falls back to scanning any registry array found on GameState,
# then tries to load a resource path matching common patterns.
func _find_invitem_by_id(id_str: String) -> Resource:
	# 1) ask GameState if it has a finder
	if has_node("/root/GameState"):
		var gs = get_node("/root/GameState")
		if gs and gs.has_method("find_invitem_by_id"):
			var f = gs.find_invitem_by_id(id_str)
			if f:
				return f

		# 2) inspect GameState.registry (accept resources OR strings)
		if gs and "registry" in gs and gs.registry:
			for entry in gs.registry:
				# resource/object: check id property
				if typeof(entry) == TYPE_OBJECT and entry != null:
					if "id" in entry and str(entry.id) == id_str:
						return entry
				# string: either a path or bare id
				elif typeof(entry) == TYPE_STRING:
					var s = str(entry).strip_edges()
					# if it's a path that exists -> load & check id
					if ResourceLoader.exists(s):
						var r = ResourceLoader.load(s)
						if r and "id" in r and str(r.id) == id_str:
							return r
					# if the registry entry is exactly the id (e.g., "001"), try candidate paths
					elif s == id_str:
						var cand = [
							"res://resources/%s_res.tres" % id_str,
							"res://resources/%s.tres" % id_str,
							"res://resources/item_%s.tres" % id_str,
							"res://resources/inv_%s.tres" % id_str
						]
						for p in cand:
							if ResourceLoader.exists(p):
								var r2 = ResourceLoader.load(p)
								if r2:
									if "id" in r2 and str(r2.id) == id_str:
										return r2
									else:
										return r2

	# 3) last resort: brute-force candidate paths
	var candidates := [
		"res://resources/%s_res.tres" % id_str,
		"res://resources/%s.tres" % id_str,
		"res://resources/item_%s.tres" % id_str,
		"res://resources/inv_%s.tres" % id_str
	]
	for p in candidates:
		if ResourceLoader.exists(p):
			var r3 = ResourceLoader.load(p)
			if r3:
				if "id" in r3 and str(r3.id) == id_str:
					return r3
				else:
					return r3

	return null

# Called after we programmatically change the player's inventory resource.
# Keeps UI and equipped weapon in sync.
func _refresh_after_inventory_change() -> void:
	# Prevent re-entrancy / infinite loops between inv_ui.update_slots() and inventory_changed signal
	if _refresh_inventory_lock:
		return
	_refresh_inventory_lock = true

	# Suppress unequip/equip racing while we update visuals
	var had_meta := false
	if not has_meta("suppress_unequip"):
		set_meta("suppress_unequip", true)
		had_meta = true
	else:
		# remember prior value so we restore it
		had_meta = (get_meta("suppress_unequip") == true)
		set_meta("suppress_unequip", true)

	# Update Inv_UI visuals if present (this will emit inventory_changed, but we suppressed handling above)
	var inv_ui = get_tree().root.find_child("Inv_UI", true, false)
	if inv_ui and inv_ui.has_method("update_slots"):
		inv_ui.update_slots()

	# If you also have a PlayerInv UI resource, update it too (defensive)
	var player_inv = get_tree().root.find_child("PlayerInv", true, false)
	if player_inv and player_inv.has_method("update_slots"):
		# avoid double-emitting the same signal if update_slots triggers inventory_changed as well
		player_inv.update_slots()

	# restore suppression flag to previous state (clear our temporary suppression)
	if has_meta("suppress_unequip"):
		# If it was previously true we leave as true; otherwise clear
		if had_meta == true:
			set_meta("suppress_unequip", true)
		else:
			remove_meta("suppress_unequip")

	# release guard before invoking equip refresh so refresh_equipped... can run
	_refresh_inventory_lock = false

	# Now refresh equipped weapon state (this will now execute since suppress_unequip was restored)
	if has_method("refresh_equipped_weapon_from_inventory"):
		refresh_equipped_weapon_from_inventory()

	# optional: autosave after programmatic inventory changes
	if has_node("/root/GameState"):
		var gs = get_node("/root/GameState")
		if gs and gs.has_method("save"):
			gs.save()
