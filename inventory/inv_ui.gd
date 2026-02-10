extends Control

signal inventory_changed

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $NinePatchRect/GridContainer.get_children()

var is_open := false
var drag_layer: CanvasLayer
var ghost_item: ItemStackUI = null
var picked_slot: InvSlot = null

signal slot_swapped(from_slot, to_slot)


# ---------------------------
# Setup
# ---------------------------
func _ready():
	print("[inv_ui][DBG READY] _ready() running; root children:", get_tree().root.get_child_count(), " groups Player->", get_tree().get_first_node_in_group("Player"))
	drag_layer = CanvasLayer.new()
	get_tree().root.call_deferred("add_child", drag_layer)

	# If player exists and player has an inventory resource, prefer to bind inv to that so UI ↔ player stay in sync
	var player = get_tree().get_first_node_in_group("Player")
	if player:
		if player.has_method("get_inventory"):
			var p_inv = player.get_inventory()
			if p_inv and inv == null:
				inv = p_inv
				print("[Inv_UI] bound inv to Player.inventory (slots:", inv.slots.size() if inv and 'slots' in inv else 0, ")")
		elif "inventory" in player and inv == null:
			inv = player.inventory
			print("[Inv_UI] bound inv to Player.inventory (slots:", inv.slots.size() if inv and 'slots' in inv else 0, ")")

	# restore main inventory (GameState) if present (keeps old behaviour)
	if has_node("/root/GameState"):
		var gs = get_node("/root/GameState")
		if gs and gs.has_method("restore_main_inventory_to_ui"):
			gs.restore_main_inventory_to_ui()

	for slot in get_children():
		if slot is InvUISlot:
			slot.connect("gui_input", Callable(self, "_on_slot_gui_input"))

	connect("slot_swapped", Callable(self, "_on_slot_swapped"))

	for i in range(slots.size()):
		slots[i].index = i

	# connect to inv resource signal and perform initial update
	if inv:
		if not inv.is_connected("inventory_changed", Callable(self, "update_slots")):
			inv.connect("inventory_changed", Callable(self, "update_slots"))
	update_slots()

	# repeat the GameState restore call AFTER update so UI visuals reflect restored slots
	if has_node("/root/GameState"):
		var gs2 = get_node("/root/GameState")
		if gs2 and gs2.has_method("restore_main_inventory_to_ui"):
			gs2.restore_main_inventory_to_ui()

	for slot in slots:
		if slot and slot.has_method("update_visual"):
			slot.update_visual()
	close()

func _process(_delta):
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()
	_update_item_in_hand()


# ---------------------------
# Slot Handling
# ---------------------------
func update_slots() -> void:
	if inv == null:
		return

	# Ensure inventory array is at least as big as UI slots
	if inv.slots.size() < slots.size():
		for i in range(slots.size() - inv.slots.size()):
			inv.slots.append(InvSlot.new())

	for i in range(slots.size()):
		if i >= inv.slots.size():
			break

		var inv_slot: InvSlot = inv.slots[i]

		# Ensure slot object always exists
		if inv_slot == null:
			inv_slot = InvSlot.new()
			inv.slots[i] = inv_slot

		# Clear visuals for empty slots
		if inv_slot.item == null:
			if slots[i].item_stack and is_instance_valid(slots[i].item_stack):
				slots[i].item_stack.queue_free()
				slots[i].item_stack = null
			continue

		# Create or reuse ItemStackUI visual
		var item_stack: ItemStackUI = slots[i].item_stack
		if item_stack == null or not is_instance_valid(item_stack):
			item_stack = isgc.instantiate()
			slots[i].insert(item_stack)

		# Connect once
		if not item_stack.clicked.is_connected(Callable(self, "_on_item_clicked")):
			item_stack.clicked.connect(Callable(self, "_on_item_clicked"))

		item_stack.slot = inv_slot
		item_stack.update()
	emit_signal("inventory_changed")


func open() -> void:
	visible = true
	is_open = true
	update_slots()
	for slot in slots:
		if slot and slot.has_method("update_visual"):
			slot.update_visual()


func close() -> void:
	visible = false
	is_open = false


# ---------------------------
# Drag & Drop
# ---------------------------
func _on_item_clicked(item_stack: ItemStackUI) -> void:
	if item_stack == null or not is_instance_valid(item_stack):
		return
	if ghost_item:
		return  # already dragging something

	# Origin slot object (may be cleared immediately)
	picked_slot = item_stack.slot

	# Save concrete item data
	var moving_item: InvItem = null
	var moving_amount: int = 0

	if picked_slot:
		moving_item = picked_slot.item
		moving_amount = picked_slot.amount

	# Instantiate ghost and stash data
	ghost_item = isgc.instantiate()
	ghost_item.slot = null
	ghost_item.origin_item = moving_item
	ghost_item.origin_amount = moving_amount
	ghost_item.origin_slot = picked_slot

	# Immediately clear origin slot
	if picked_slot:
		picked_slot.item = null
		picked_slot.amount = 0

	update_slots()
	for slot in slots:
		if slot and slot.has_method("update_visual"):
			slot.update_visual()

	# Add ghost to drag layer
	drag_layer.add_child(ghost_item)
	ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ghost_item.call_deferred("update")
	ghost_item.visible = true

	# Hide the real UI item if still around
	if is_instance_valid(item_stack):
		item_stack.visible = false

	_update_item_in_hand()

# ---------------------------
# Drag & drop handling
# ---------------------------
func _unhandled_input(event: InputEvent) -> void:
	if not ghost_item:
		return

	if event is InputEventMouseButton and not event.pressed:
		var mouse_pos = get_viewport().get_mouse_position()
		var dropped = false
		var moving_item: InvItem = ghost_item.origin_item
		var moving_amount: int = ghost_item.origin_amount

		# Find reference to player inventory
		var player_inv := get_tree().root.find_child("PlayerInv", true, false)

		# 1️⃣ Drop inside main inventory (self)
		for slot in slots:
			if slot.get_global_rect().has_point(mouse_pos):
				var target_slot: InvSlot = inv.slots[slot.index]

				if moving_item == null:
					dropped = true
					break

				if picked_slot != null and target_slot == picked_slot:
					target_slot.item = moving_item
					target_slot.amount = moving_amount
					dropped = true
					break

				if target_slot.item and target_slot.item.id == moving_item.id and not _is_non_stackable(moving_item):
					target_slot.amount += moving_amount
				elif target_slot.item:
					var temp_item = target_slot.item
					var temp_amount = target_slot.amount
					target_slot.item = moving_item
					target_slot.amount = moving_amount
					if picked_slot:
						picked_slot.item = temp_item
						picked_slot.amount = temp_amount
				else:
					target_slot.item = moving_item
					target_slot.amount = moving_amount

				dropped = true
				break

		# 2️⃣ Drop into player inventory
		if not dropped and player_inv and player_inv.visible and player_inv.is_mouse_over_ui(mouse_pos):
			for pslot in player_inv.slots:
				if pslot.get_global_rect().has_point(mouse_pos):
					var slot_t := str(pslot.slot_type).to_lower()
					var item_t := str(moving_item.type).to_lower()

					if not player_inv._can_accept_item(slot_t, item_t):
						print("[inv_ui] ❌ Invalid drop —", moving_item.type, "cannot go into", pslot.slot_type)
						continue

					var idx = player_inv.slots.find(pslot)
					if idx == -1:
						continue

					# Ensure the resource slot exists
					while player_inv.inv.slots.size() <= idx:
						player_inv.inv.slots.append(InvSlot.new())
					var target_slot: InvSlot = player_inv.inv.slots[idx]

					# Place / swap logic
					if target_slot.item == null:
						target_slot.item = moving_item
						target_slot.amount = moving_amount
					else:
						# swap with whatever was in the player slot
						var tmp_item = target_slot.item
						var tmp_amt = target_slot.amount
						target_slot.item = moving_item
						target_slot.amount = moving_amount
						if picked_slot:
							picked_slot.item = tmp_item
							picked_slot.amount = tmp_amt

					# --- Robust equip logic (REPLACE EXISTING equip block WITH THIS) ---
					var player_node := get_tree().root.find_child("Player", true, false)
					if player_node:
						if slot_t == "weapon":
							# Defensive: ensure target resource is set first (we set target_slot.item earlier)
							# Try to produce the *type* the player's equip function expects:
							var equip_arg = null
							var loaded_scene = null

							# 1) If there's an explicit scene_path, try to load it (PackedScene or Resource).
							if moving_item and moving_item.scene_path != "":
								if ResourceLoader.exists(moving_item.scene_path):
									loaded_scene = ResourceLoader.load(moving_item.scene_path)
									# prefer PackedScene / Resource instance
									equip_arg = loaded_scene

							# 2) If no scene loaded, fall back to the InvItem resource itself (some projects accept that)
							if equip_arg == null:
								equip_arg = moving_item

							# 3) Call equip in a safe way depending on what player's API accepts
							var did_equip := false
							if player_node.has_method("equip_weapon"):
								# Try variants: PackedScene/resource first, then path string
								# If equip_weapon expects a path, passing equip_arg (PackedScene) may still fail — try both.
								# We'll attempt to call with equip_arg, then fallback to scene_path string.
								match typeof(equip_arg):
									TYPE_OBJECT:
										# object / resource passed
										player_node.equip_weapon(equip_arg)
										did_equip = true
									_:
										# try string fallback
										if moving_item and moving_item.scene_path != "":
											player_node.equip_weapon(moving_item.scene_path)
											did_equip = true

							# 4) Mark player state + refresh visuals
							player_node.has_weapon = true
							if player_node.has_method("refresh_equipped_weapon_from_inventory"):
								player_node.refresh_equipped_weapon_from_inventory()
							if player_node.has_method("update_weapon_visuals"):
								player_node.update_weapon_visuals()

							# 5) Force UI ghost to update so hand shows the equipped weapon (if dragging)
							if ghost_item and is_instance_valid(ghost_item):
								# prefer icon, fallback to texture
								if moving_item.icon and "item_visual" in ghost_item:
									ghost_item.item_visual.texture = moving_item.icon
								elif moving_item.texture and "item_visual" in ghost_item:
									ghost_item.item_visual.texture = moving_item.texture
								ghost_item.call_deferred("update")
								_update_item_in_hand()

							# Debug
							print("[EQUIP] weapon equip attempt; player_node:", player_node, "equip_arg:", equip_arg, "loaded_scene:", loaded_scene, "moving_item:", moving_item)
						elif slot_t == "armor":
							if moving_item.scene_path != "" and player_node.has_method("equip_armor"):
								# same robust loading pattern for armor if needed
								if ResourceLoader.exists(moving_item.scene_path):
									player_node.equip_armor(ResourceLoader.load(moving_item.scene_path))
								else:
									player_node.equip_armor(moving_item)
							# optional refresh
							if player_node.has_method("refresh_equipped_armor_from_inventory"):
								player_node.refresh_equipped_armor_from_inventory()

					dropped = true

					# signal UI to update
					if player_inv:
						player_inv.update_slots()
					break

		# 3️⃣ Drop outside → spawn world drop (REPLACEMENT)
		if not dropped and moving_item:
			# detect whether mouse is over UI background; if so restore
			var ui_under_mouse := false
			if get_global_rect().has_point(mouse_pos):
				ui_under_mouse = true
			elif player_inv and player_inv.visible and player_inv.get_global_rect().has_point(mouse_pos):
				ui_under_mouse = true

			if ui_under_mouse:
				print("[inv_ui] ⛔ Mouse over inventory background, cancelling drop")
				if picked_slot:
					picked_slot.item = moving_item
					picked_slot.amount = moving_amount
				dropped = true
			else:
				var world_item_scene = preload("res://scenes/world_item.tscn")
				var world_item := world_item_scene.instantiate()
				# assign item & quantity if those properties exist
				if "item" in world_item:
					world_item.item = moving_item
				if "quantity" in world_item:
					world_item.quantity = moving_amount

				# Set texture safely (prefer 'texture' over 'icon')
				if moving_item.texture and world_item.has_node("Sprite2D"):
					world_item.get_node("Sprite2D").texture = moving_item.texture
					if "world_texture" in world_item:
						world_item.world_texture = moving_item.texture
				elif moving_item.icon and world_item.has_node("Sprite2D"):
					world_item.get_node("Sprite2D").texture = moving_item.icon
					if "world_texture" in world_item:
						world_item.world_texture = moving_item.icon

				# Place near player (global coords) or mouse as fallback
				var spawn_pos: Vector2
				var player_node := get_tree().root.find_child("Player", true, false)
				if player_node != null:
					spawn_pos = player_node.global_position + Vector2(0, -16)
				else:
					spawn_pos = mouse_pos

				# Use your YSort-aware helper to parent the world item (DO NOT set z_index here)
				_spawn_world_item(world_item, spawn_pos)

				print("[inv_ui] 🌍 Dropped item near player at:", world_item.global_position)
				print("[inv_ui] 🌍 Dropped item near player:", moving_item.name)
				dropped = true

				print("[inv_ui] 🌍 Dropped item near player:", moving_item.name)

		# Cleanup
		if ghost_item:
			ghost_item.queue_free()
		ghost_item = null
		picked_slot = null

		# Refresh visuals
		update_slots()
		for slot in slots:
			if slot and slot.has_method("update_visual"):
				slot.update_visual()
		if player_inv:
			player_inv.update_slots()
	emit_signal("inventory_changed")

func _update_item_in_hand():
	if ghost_item == null:
		return
	var mouse_pos = get_viewport().get_mouse_position()
	var offset = Vector2.ZERO
	if ghost_item is Control:
		offset = ghost_item.size * 0.5
	ghost_item.global_position = mouse_pos - offset


# ---------------------------
# Helpers
# ---------------------------
func _is_non_stackable(item: InvItem) -> bool:
	if not item:
		return false
	return item.type == "weapon" or item.type == "armor"


func get_slots_rects() -> Array[Rect2]:
	var rects := []
	for s in slots:
		if s and s is Control:
			rects.append(s.get_global_rect())
	return rects


func get_slot_under_mouse(pos: Vector2) -> int:
	for i in range(slots.size()):
		if slots[i].get_global_rect().has_point(pos):
			return i
	return -1


func is_mouse_over_ui(mouse_pos: Vector2) -> bool:
	return get_global_rect().has_point(mouse_pos)

func get_slot_by_type(slot_type: String) -> InvUISlot:
	for slot in slots:
		if slot and str(slot.slot_type).to_lower() == str(slot_type).to_lower():
			print("[get_slot_by_type] ✅ found", slot.name, "type:", slot.slot_type)
			return slot
	print("[get_slot_by_type] ❌ no slot of type", slot_type)
	return null

func _on_slot_swapped(from_slot: InvUISlot, to_slot: InvUISlot) -> void:
	print("[inv_ui][DBG _on_slot_swapped] from:", from_slot.slot_type, " to:", to_slot.slot_type)
	var player = get_tree().get_first_node_in_group("Player")
	if not player:
		player = get_tree().get_first_node_in_group("player")
	print("[inv_ui][DBG _on_slot_swapped] resolved player ->", player, " suppress_unequip:", (player.get_meta("suppress_unequip") if player and player.has_meta("suppress_unequip") else "false"))
	if not player:
		return


	# If the player temporarily suppressed unequip (to avoid UI race), skip unequip
	if player.has_meta("suppress_unequip") and player.get_meta("suppress_unequip") == true:
		print("[inv_ui][DBG] suppress_unequip active, skipping unequip for slot swap")
	else:
		if from_slot.slot_type == "weapon" and to_slot.item_stack == null:
			player.unequip_weapon()

	# Weapon slot update (existing behavior)
	if to_slot.slot_type == "weapon" and to_slot.item_stack:
		player.equip_weapon(to_slot.item_stack.item.scene_path)
	elif from_slot.slot_type == "weapon" and to_slot.item_stack == null:
		player.has_weapon = false

@onready var message_label: Label = $MessageLayer/MessageLabel

func show_message(text: String) -> void:
	print("[Inv_UI] show_message() called with text:", text)

	# --- ensure MessageLayer exists under the SCENE ROOT ---
	var layer: CanvasLayer
	if get_tree().root.has_node("MessageLayer"):
		layer = get_tree().root.get_node("MessageLayer") as CanvasLayer
	else:
		layer = CanvasLayer.new()
		layer.name = "MessageLayer"
		get_tree().root.add_child(layer)
		await get_tree().process_frame # ensure registration
		print("[Inv_UI] Created MessageLayer directly under root")

	# --- ensure MessageLabel exists inside the layer ---
	var label: Label
	if layer.has_node("MessageLabel"):
		label = layer.get_node("MessageLabel") as Label
		print("[Inv_UI] Found existing MessageLabel")
	else:
		label = Label.new()
		label.name = "MessageLabel"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.visible = false
		layer.add_child(label)
		await get_tree().process_frame
		print("[Inv_UI] Created MessageLabel dynamically")

	# --- setup label visuals ---
	label.text = text
	label.z_index = 9999
	label.custom_minimum_size = Vector2.ZERO

	# ✅ Keep red color, add black outline
	var settings := LabelSettings.new()
	settings.font_color = Color(1.0, 0.0, 0.0) # red
	settings.outline_size = 4                  # border thickness
	settings.outline_color = Color.BLACK       # black outline
	label.label_settings = settings

	# start transparent (red)
	label.modulate = Color(1.0, 0.0, 0.0, 0.0)

	# --- debug info about hierarchy ---
	print("[Inv_UI][DEBUG] layer parent:", layer.get_parent())
	print("[Inv_UI][DEBUG] layer.layer (CanvasLayer index):", layer.layer)
	print("[Inv_UI][DEBUG] label parent:", label.get_parent())

	# wait one frame for layout stabilization
	await get_tree().process_frame

	# --- compute layout ---
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var min_size: Vector2 = label.get_minimum_size()
	var width: float = clamp(viewport_size.x * 0.6, 200.0, viewport_size.x - 40.0)
	var height: float = max(min_size.y, 22.0)
	var pos_x: float = (viewport_size.x - width) * 0.5
	var bottom_y: float = viewport_size.y - 80.0

	label.custom_minimum_size = Vector2(width, height)
	label.position = Vector2(pos_x, bottom_y)
	label.visible = true

	print("[Inv_UI][DEBUG] viewport_size:", viewport_size,
		" min_size:", min_size,
		" label.position:", label.position)

	# --- handle any existing tween ---
	if label.has_meta("tween"):
		var old_tween: Tween = label.get_meta("tween") as Tween
		if old_tween and old_tween.is_running():
			old_tween.kill()
			print("[Inv_UI][DEBUG] Killed old tween")
		label.set_meta("tween", null)

	# --- create animation tween ---
	var tween: Tween = create_tween()
	label.set_meta("tween", tween)

	# fade in
	tween.tween_property(label, "modulate:a", 1.0, 0.18)

	# shake effect
	var base_pos: Vector2 = label.position
	for i in range(3):
		tween.tween_property(label, "position:x", base_pos.x + randf_range(-6.0, 6.0), 0.06)
		tween.tween_property(label, "position:x", base_pos.x, 0.06)

	# hold, then fade out
	tween.tween_interval(1.0)
	tween.tween_property(label, "modulate:a", 0.0, 0.35)

	# cleanup
	tween.tween_callback(Callable(label, "hide"))
	tween.finished.connect(Callable(self, "_on_message_tween_finished"))

	print("[Inv_UI][DEBUG] Tween started for:", text, "at position:", label.position)

func _on_message_tween_finished() -> void:
	if has_node("MessageLayer/MessageLabel"):
		var lbl: Label = $MessageLayer/MessageLabel
		if lbl and lbl.has_meta("tween"):
			lbl.set_meta("tween", null)
		lbl.visible = false
		lbl.modulate = Color(1.0, 0.0, 0.0, 0.0)
		print("[Inv_UI][DEBUG] MessageLabel hidden/reset")

func _show_message_deferred(text: String) -> void:
	if not is_instance_valid(message_label):
		print("[Inv_UI][DEBUG] message_label invalid")
		return

	var vp_rect := get_viewport().get_visible_rect()
	var vp_center := vp_rect.size * 0.5
	var lbl_size := Vector2(150, 30)

	if "rect_size" in message_label:
		lbl_size = message_label.rect_size
	elif message_label.size.length() > 0:
		lbl_size = message_label.size

	var final_pos := vp_center - lbl_size * 0.5 + Vector2(0, -100)
	message_label.global_position = final_pos
	print("[Inv_UI][DEBUG] viewport:", vp_rect, "label pos:", final_pos, "lbl_size:", lbl_size)

	# 💡 ensure label is visible and on top
	message_label.show()
	message_label.z_index = 9999
	message_label.visible = true

	# 🌀 Fade + shake animation
	var tween := create_tween()
	tween.tween_property(message_label, "modulate:a", 1.0, 0.25)
	tween.tween_property(message_label, "scale", Vector2(1.1, 1.1), 0.1)
	tween.tween_property(message_label, "scale", Vector2(1.0, 1.0), 0.1).set_delay(0.1)

	var base_pos := message_label.position
	for i in range(4):
		var offset := Vector2(((-1) ** i) * 6, 0)
		tween.tween_property(message_label, "position", base_pos + offset, 0.04)
	tween.tween_property(message_label, "position", base_pos, 0.04)

	tween.tween_property(message_label, "modulate:a", 0.0, 0.5).set_delay(0.7)
	tween.finished.connect(func ():
		if is_instance_valid(message_label):
			message_label.hide()
			print("[Inv_UI] message_label hidden after animation"))

func _spawn_world_item(world_item: Node2D, spawn_pos: Vector2) -> void:
	# set global position first (so any YSort/global-y logic works)
	world_item.global_position = spawn_pos

	# choose parent using helper (prefer a YSort node)
	var parent := _get_world_ysort_parent()
	if parent == null:
		parent = get_tree().current_scene if get_tree().current_scene else get_tree().root

	# add to chosen parent (if it's a YSort it will sort automatically)
	parent.add_child(world_item)

	# debug hint
	print("[spawn_world_item] parent:", parent, " class:", (parent.get_class() if parent and parent.has_method("get_class") else "Unknown"))

func _get_world_ysort_parent() -> Node:
	var world_scene := get_tree().current_scene

	# 1) Try obvious names on the current scene (exact)
	if world_scene:
		var named := ["YSort", "Y-Sort", "y_sort", "y-sort", "ySort"]
		for n in named:
			var candidate := world_scene.get_node_or_null(n)
			if candidate:
				# prefer a true YSort node
				if candidate.has_method("get_class") and candidate.get_class() == "YSort":
					return candidate
				# if the node is present and named that way, return it as fallback
				return candidate

		# 2) recursive search for actual YSort class
		var found := _find_first_ysort_recursive(world_scene)
		if found:
			return found

	# 3) fallback to root paths commonly used
	var root_paths := ["world/Y-Sort", "world/YSort", "world/layers/Y-Sort", "world/layers/YSort", "world/layers/Resources"]
	for p in root_paths:
		var node := get_tree().root.get_node_or_null(p)
		if node:
			# prefer true YSort if it is one
			if node.has_method("get_class") and node.get_class() == "YSort":
				return node
			return node

	# last resorts
	if world_scene:
		return world_scene
	return get_tree().root

func _find_first_ysort_recursive(node: Node) -> Node:
	for child in node.get_children():
		if child == null:
			continue
		if child.has_method("get_class") and child.get_class() == "YSort":
			return child
		var deeper := _find_first_ysort_recursive(child)
		if deeper:
			return deeper
	return null
