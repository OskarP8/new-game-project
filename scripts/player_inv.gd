extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $".".get_children()

var is_open := false
var ghost_item = null
var picked_slot: InvSlot = null

func _ready():
	if inv:
		inv.inventory_changed.connect(update_slots)
	for s in slots:
		if s is InvUISlot:
			s.item_dropped_from_slot.connect(_on_item_dropped_from_slot)
	update_slots()
	close()

func _process(_delta):
	if Input.is_action_just_pressed("i"): # or "i" if preferred
		if is_open:
			close()
		else:
			open()
	if ghost_item:
		_update_ghost_position()

# --- Inventory toggle ---
func open():
	visible = true
	is_open = true
	update_slots()

func close():
	visible = false
	is_open = false

# --- Update UI ---
func update_slots() -> void:
	if inv == null:
		print("[player_inv] ⚠ No inventory resource assigned!")
		return

	for i in range(slots.size()):
		var ui_slot: InvUISlot = slots[i]

		# ✅ Ensure inv.slots is large enough
		while inv.slots.size() <= i:
			inv.slots.append(InvSlot.new())

		# ✅ Ensure slot object is never null
		if inv.slots[i] == null:
			inv.slots[i] = InvSlot.new()

		var inv_slot: InvSlot = inv.slots[i]

		# ✅ Clean up broken item_stack references
		if ui_slot.item_stack and not is_instance_valid(ui_slot.item_stack):
			ui_slot.item_stack = null

		# ✅ If no item in this slot — remove any visible item stack
		if inv_slot.item == null:
			if ui_slot.item_stack:
				if ui_slot.container.has_node(ui_slot.item_stack.get_path()):
					ui_slot.container.remove_child(ui_slot.item_stack)
				ui_slot.item_stack.queue_free()
				ui_slot.item_stack = null
			continue

		# ✅ Create or reuse ItemStackUI visual
		var item_stack: ItemStackUI = ui_slot.item_stack
		if item_stack == null:
			item_stack = isgc.instantiate()
			ui_slot.insert(item_stack)
			ui_slot.item_stack = item_stack
			# connect signal safely once
			if not item_stack.clicked.is_connected(Callable(self, "_on_item_clicked")):
				item_stack.clicked.connect(Callable(self, "_on_item_clicked").bind(item_stack))

		item_stack.slot = inv_slot
		item_stack.update()

# --- Picking up item ---
func _on_item_clicked(item_stack: ItemStackUI) -> void:
	print("[player_inv] Picked up:", item_stack.slot.item)
	picked_slot = item_stack.slot

	# detach from slot
	if item_stack.get_parent():
		item_stack.get_parent().remove_child(item_stack)

	# create ghost item for dragging
	ghost_item = item_stack
	ghost_item.origin_item = picked_slot.item
	ghost_item.origin_amount = picked_slot.amount
	ghost_item.origin_slot = picked_slot

	add_child(ghost_item)
	ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ghost_item.z_index = 999
	_update_ghost_position()

func _update_ghost_position():
	if ghost_item:
		ghost_item.global_position = get_viewport().get_mouse_position() - ghost_item.size * 0.5

# --- Drop handling ---
func _unhandled_input(event: InputEvent) -> void:
	if ghost_item == null or picked_slot == null:
		return

	if event is InputEventMouseButton and not event.pressed:
		var mouse_pos = get_viewport().get_mouse_position()
		var dropped := false
		var moving_item := picked_slot.item
		var moving_amount := picked_slot.amount

		var inv_ui := get_tree().root.find_child("Inv_UI", true, false)
		var player := get_tree().root.find_child("Player", true, false)

		# Clear picked slot for now
		picked_slot.item = null
		picked_slot.amount = 0

		# --- 1️⃣ Drop inside player equipment (PlayerInv) ---
		for idx in range(slots.size()):
			var slot_node = slots[idx]
			if slot_node.get_global_rect().has_point(mouse_pos):
				var slot_type = slot_node.slot_type
				print("[player_inv] Hovered slot:", slot_type, "→ item type:", moving_item.type)

				if not _can_accept_item(slot_type, moving_item.type):
					print("[player_inv] ❌ Can't place", moving_item.type, "into", slot_type)
					continue

				var target_slot: InvSlot = inv.slots[idx]
				if target_slot == null:
					target_slot = InvSlot.new()
					inv.slots[idx] = target_slot

				# --- Empty slot: place item ---
				if target_slot.item == null:
					print("[player_inv] ✅ Placed", moving_item.name, "in", slot_type)
					target_slot.item = moving_item
					target_slot.amount = moving_amount

					# ✅ Equip weapon or armor when placed (safe checks)
					var player_node: Node = get_tree().get_root().find_node("Player", true, false)
					if player_node == null:
						print("[player_inv] ⚠ Player node not found — can't auto-equip")
					else:
						if moving_item.type == "weapon":
							if moving_item.scene_path != "":
								if player_node.has_method("equip_weapon"):
									print("[player_inv] -> equipping weapon:", moving_item.scene_path)
									player_node.equip_weapon(moving_item.scene_path)
								else:
									print("[player_inv] ⚠ Player node has no equip_weapon()")
							else:
								print("[player_inv] ⚠ Item has no scene_path, cannot equip:", moving_item.name)
						elif moving_item.type == "armor":
							if moving_item.scene_path != "":
								if player_node.has_method("equip_armor"):
									print("[player_inv] -> equipping armor:", moving_item.scene_path)
									player_node.equip_armor(moving_item.scene_path)
								else:
									print("[player_inv] ⚠ Player node has no equip_armor()")
							else:
								print("[player_inv] ⚠ Item has no scene_path, cannot equip:", moving_item.name)

				# --- Swapping items ---
				else:
					print("[player_inv] 🔄 Swapped", moving_item.name, "with existing item")
					var tmp_item = target_slot.item
					var tmp_amt = target_slot.amount
					target_slot.item = moving_item
					target_slot.amount = moving_amount
					picked_slot.item = tmp_item
					picked_slot.amount = tmp_amt

					# Re-equip the new item if appropriate
					var player_node2: Node = get_tree().get_root().find_node("Player", true, false)
					if player_node2:
						# If the new target_slot has a weapon, equip it
						if target_slot.item and target_slot.item.type == "weapon":
							if target_slot.item.scene_path != "" and player_node2.has_method("equip_weapon"):
								print("[player_inv] -> equipping swapped-in weapon:", target_slot.item.scene_path)
								player_node2.equip_weapon(target_slot.item.scene_path)
						elif target_slot.item and target_slot.item.type == "armor":
							if target_slot.item.scene_path != "" and player_node2.has_method("equip_armor"):
								print("[player_inv] -> equipping swapped-in armor:", target_slot.item.scene_path)
								player_node2.equip_armor(target_slot.item.scene_path)

				dropped = true
				break

		# --- 2️⃣ Drop into main inventory (Inv_UI) ---
		if not dropped and inv_ui and inv_ui.visible:
			for inv_slot_node in inv_ui.slots:
				if inv_slot_node.get_global_rect().has_point(mouse_pos):
					var target_slot: InvSlot = inv_ui.inv.slots[inv_ui.slots.find(inv_slot_node)]
					if target_slot == null:
						target_slot = InvSlot.new()
						inv_ui.inv.slots[inv_ui.slots.find(inv_slot_node)] = target_slot

					if target_slot.item == null:
						print("[player_inv] ✅ Moved", moving_item.name, "to inventory")
						target_slot.item = moving_item
						target_slot.amount = moving_amount
					else:
						print("[player_inv] 🔄 Swapped", moving_item.name, "with inventory item")
						var tmp_item = target_slot.item
						var tmp_amt = target_slot.amount
						target_slot.item = moving_item
						target_slot.amount = moving_amount
						picked_slot.item = tmp_item
						picked_slot.amount = tmp_amt
					dropped = true
					break

		# --- 3️⃣ Dropped outside everything ---
		if not dropped:
			print("[player_inv] 🗑 Dropped outside, restoring item to original slot")
			picked_slot.item = moving_item
			picked_slot.amount = moving_amount

		# --- 4️⃣ Unequip if weapon slot emptied ---
		if player:
			for i in range(slots.size()):
				var slot_node = slots[i]
				if slot_node.slot_type == "weapon":
					var s := inv.slots[i]
					if s == null or s.item == null:
						player.equip_weapon(null)
				elif slot_node.slot_type == "armor":
					var s := inv.slots[i]
					if s == null or s.item == null:
						player.equip_armor(null)

		# --- Cleanup ---
		if ghost_item and is_instance_valid(ghost_item):
			ghost_item.queue_free()
			ghost_item = null
		picked_slot = null

		update_slots()
		if inv_ui:
			inv_ui.update_slots()

func _can_accept_item(slot_type: String, item_type: String) -> bool:
	if slot_type == null or item_type == null:
		return false
	slot_type = slot_type.to_lower()
	item_type = item_type.to_lower()
	match slot_type:
		"weapon", "secondary":
			return item_type == "weapon"
		"armor":
			return item_type == "armor"
		"consumable":
			return item_type == "consumable"
		_:
			# generic fallback for non-restricted slots
			return true

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

func _on_item_dropped_from_slot(slot: InvUISlot, item: InvItem, amount: int) -> void:
	print("[player_inv] Item dragged out from", slot.slot_type, ":", item.name)

	# Unequip logic when dragging from equipped slots
	var player := get_tree().get_first_node_in_group("Player")
	if player == null:
		return

	match slot.slot_type:
		"weapon":
			player.equip_weapon(null)
		"armor":
			if player.has_method("equip_armor"):
				player.equip_armor(null)

	# Create ghost item so player can drag it to inventory
	var ghost := preload("res://scenes/item_stack_ui.tscn").instantiate()
	ghost.origin_item = item
	ghost.origin_amount = amount
	ghost.slot = null
	add_child(ghost)
	ghost.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ghost.global_position = get_viewport().get_mouse_position() - ghost.size * 0.5
func get_slot_by_type(slot_type: String) -> InvUISlot:
	for slot in slots:
		if slot and slot.has_meta("slot_type"):  # optional, if you store slot_type as metadata
			if str(slot.get_meta("slot_type")).to_lower() == slot_type.to_lower():
				return slot
		elif "slot_type" in slot and slot.slot_type != null:
			if str(slot.slot_type).to_lower() == slot_type.to_lower():
				return slot
	push_warning("[PlayerInv] ❌ No slot of type %s found" % slot_type)
	return null
