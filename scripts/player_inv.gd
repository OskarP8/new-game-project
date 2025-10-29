extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $".".get_children()

var is_open := false
var ghost_item = null
var picked_slot: InvSlot = null
var drag_layer: CanvasLayer

func _ready():
	if inv:
		inv.inventory_changed.connect(update_slots)
	else:
		print("[player_inv] ⚠ No Inv resource assigned!")

	for s in slots:
		if s is InvUISlot:
			s.item_dropped_from_slot.connect(_on_item_dropped_from_slot)
	drag_layer = CanvasLayer.new()
	get_tree().root.call_deferred("add_child", drag_layer)
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

	print("[player_inv] 🔄 Updating slots — total:", slots.size())

	for i in range(slots.size()):
		var ui_slot: InvUISlot = slots[i]

		# Ensure resource slot exists
		while inv.slots.size() <= i:
			inv.slots.append(InvSlot.new())

		if inv.slots[i] == null:
			inv.slots[i] = InvSlot.new()

		var inv_slot: InvSlot = inv.slots[i]

		# Clean up invalid references
		if ui_slot.item_stack and not is_instance_valid(ui_slot.item_stack):
			ui_slot.item_stack = null

		# No item → remove any visuals
		if inv_slot.item == null:
			if ui_slot.item_stack:
				print("[player_inv] 🧹 Clearing slot", i)
				ui_slot.item_stack.queue_free()
				ui_slot.item_stack = null
			continue

		# Create or reuse ItemStackUI
		var item_stack: ItemStackUI = ui_slot.item_stack
		if item_stack == null:
			item_stack = isgc.instantiate()
			ui_slot.insert(item_stack)
			ui_slot.item_stack = item_stack
			print("[player_inv] 🧩 Created new ItemStackUI for slot", i)
		else:
			print("[player_inv] ♻ Reusing existing ItemStackUI for slot", i)

		# Connect the click signal every time (safe rebind)
		if not item_stack.clicked.is_connected(Callable(self, "_on_item_clicked")):
			item_stack.clicked.connect(Callable(self, "_on_item_clicked"))
			print("[player_inv] ✅ Connected clicked signal for slot", i, "→", inv_slot.item.name)
		else:
			print("[player_inv] (already connected) slot", i)

		item_stack.slot = inv_slot
		item_stack.update()

func _on_item_clicked(item_stack: ItemStackUI) -> void:
	# Basic guard
	if item_stack == null or not is_instance_valid(item_stack):
		print("[player_inv][_on_item_clicked] ❌ item_stack invalid or null")
		return

	# Already dragging?
	# Inside _on_item_clicked or _on_item_dropped_from_slot
	if ghost_item:
		if ghost_item.get_parent():
			ghost_item.get_parent().remove_child(ghost_item)
		drag_layer.add_child(ghost_item)
		ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)

	# Report click
	print("[player_inv][_on_item_clicked] clicked ItemStackUI:", item_stack, " parent:", item_stack.get_parent())

	# Resolve origin slot reference
	picked_slot = item_stack.slot
	print("[player_inv][_on_item_clicked] picked_slot:", picked_slot)

	if picked_slot == null:
		print("[player_inv][_on_item_clicked] ⚠ picked_slot is null — aborting")
		return

	# Print slot contents before clearing
	print("[player_inv][_on_item_clicked] origin slot contents BEFORE clear -> item:", picked_slot.item, " amount:", picked_slot.amount)

	# Create ghost reference (reuse the visual node)
	ghost_item = item_stack
	ghost_item.origin_item = picked_slot.item
	ghost_item.origin_amount = picked_slot.amount
	ghost_item.origin_slot = picked_slot

	# Immediately clear the origin slot so UI shows empty while dragging
	picked_slot.item = null
	picked_slot.amount = 0
	print("[player_inv][_on_item_clicked] origin slot cleared -> now item:", picked_slot.item, " amount:", picked_slot.amount)

	# Refresh visuals so the original slot immediately appears empty
	update_slots()
	print("[player_inv][_on_item_clicked] update_slots() called")

	# Move the ghost to the scene root (top-level) so it draws above UI
	var root = get_tree().root
	# remove from previous parent if necessary
	if is_instance_valid(ghost_item.get_parent()):
		var prev_parent = ghost_item.get_parent()
		prev_parent.remove_child(ghost_item)
		print("[player_inv][_on_item_clicked] removed ghost from previous parent:", prev_parent)

	root.add_child(ghost_item)
	print("[player_inv][_on_item_clicked] added ghost to root:", ghost_item.get_parent())

	# Configure ghost as Control (positioning and z)
	if ghost_item is Control:
		ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)
		ghost_item.z_index = 999
		_update_ghost_position()
		print("[player_inv][_on_item_clicked] ghost positioned at:", ghost_item.global_position)
	else:
		print("[player_inv][_on_item_clicked] ⚠ ghost_item is not Control, class:", ghost_item.get_class())

	# Hide the real UI instance if it still exists (defensive)
	if is_instance_valid(item_stack):
		item_stack.visible = false
		print("[player_inv][_on_item_clicked] hid original item_stack visual:", item_stack)

	print("[player_inv][_on_item_clicked] ghost origin_item:", ghost_item.origin_item, " origin_amount:", ghost_item.origin_amount)

func _update_ghost_position():
	if ghost_item and is_instance_valid(ghost_item):
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

	# Determine which resource slot (InvSlot) this UI slot corresponds to
	var idx := slots.find(slot)
	if idx == -1:
		push_warning("[player_inv] ❌ Could not find UI slot index for: " + str(slot))
		return

	# store the InvSlot resource so subsequent drop logic can restore if needed
	picked_slot = inv.slots[idx]
	if picked_slot == null:
		# create a placeholder slot if resource missing
		picked_slot = InvSlot.new()
		inv.slots[idx] = picked_slot

	# DEBUG
	print("[player_inv] _on_item_dropped_from_slot -> ui_index:", idx, " picked_slot:", picked_slot, " item:", item, "amount:", amount)

	# Unequip logic when dragging from equipped slots
	var player := get_tree().get_first_node_in_group("Player")
	if player == null:
		print("[player_inv] ⚠ Player node not found")
	else:
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

	# put the ghost at root so it draws above UI
	get_tree().root.add_child(ghost)
	ghost.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ghost.global_position = get_viewport().get_mouse_position() - ghost.size * 0.5

	# store it so the rest of your _unhandled_input logic can use it
	ghost_item = ghost

	print("[player_inv] ghost created and picked_slot stored.")

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
