extends Control

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
	drag_layer = CanvasLayer.new()
	get_tree().root.call_deferred("add_child", drag_layer)

	for slot in get_children():
		if slot is InvUISlot:
			slot.connect("gui_input", Callable(self, "_on_slot_gui_input"))

	connect("slot_swapped", Callable(self, "_on_slot_swapped"))

	for i in range(slots.size()):
		slots[i].index = i

	if inv:
		if not inv.is_connected("inventory_changed", Callable(self, "update_slots")):
			inv.connect("inventory_changed", Callable(self, "update_slots"))
	update_slots()
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
					var target_slot: InvSlot = player_inv.inv.slots[idx]

					if target_slot.item == null:
						print("[inv_ui] ✅ Placed", moving_item.name, "into", pslot.slot_type)

						# Auto-equip weapons when dropped into weapon slot
						if str(pslot.slot_type).to_lower() == "weapon":
							var player := get_tree().root.find_child("Player", true, false)
							if player and moving_item and moving_item.scene_path != "":
								print("[inv_ui] 🗡 Equipping weapon from:", moving_item.scene_path)
								player.equip_weapon(moving_item.scene_path)
							else:
								print("[inv_ui] ⚠️ Could not equip weapon — missing player or scene_path")

						target_slot.item = moving_item
						target_slot.amount = moving_amount

					else:
						print("[inv_ui] 🔄 Swapped with existing item in", pslot.slot_type)
						var tmp_item = target_slot.item
						var tmp_amt = target_slot.amount
						target_slot.item = moving_item
						target_slot.amount = moving_amount
						picked_slot.item = tmp_item
						picked_slot.amount = tmp_amt

					dropped = true
					break

		# 3️⃣ Drop outside → spawn world drop
		if not dropped and moving_item:
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
				var world_item: WorldItem = world_item_scene.instantiate()
				world_item.item = moving_item
				world_item.quantity = moving_amount

				# Debug info
				print("[inv_ui][DEBUG] moving_item resource:", moving_item)
				print("[inv_ui][DEBUG] moving_item.texture:", moving_item.texture)
				print("[inv_ui][DEBUG] moving_item.icon:", moving_item.icon)

				# Force using the 'texture' property
				if moving_item.texture:
					print("[inv_ui][DEBUG] Setting world sprite texture to moving_item.texture")
					if world_item.has_node("Sprite2D"):
						world_item.get_node("Sprite2D").texture = moving_item.texture
					world_item.world_texture = moving_item.texture
				else:
					print("[inv_ui][DEBUG] ⚠️ moving_item.texture not found, fallback to icon")
					if moving_item.icon and world_item.has_node("Sprite2D"):
						world_item.get_node("Sprite2D").texture = moving_item.icon
						world_item.world_texture = moving_item.icon

				# Drop near player
				var player = get_tree().root.find_child("Player", true, false)
				if player:
					world_item.position = player.global_position + Vector2(0, -16)
					world_item.z_index = int(world_item.position.y)
				else:
					world_item.position = Vector2.ZERO

				get_tree().current_scene.add_child(world_item)
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
	var player = get_tree().get_first_node_in_group("player")
	if not player:
		return

	# Weapon slot update
	if to_slot.slot_type == "weapon" and to_slot.item_stack:
		player.equip_weapon(to_slot.item_stack.item)
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
