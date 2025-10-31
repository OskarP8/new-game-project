extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $".".get_children()

var is_open := false
var picked_slot: InvSlot = null
var drag_layer: CanvasLayer
var dragging := false
var ghost_item: ItemStackUI = null

func _ready():
	if inv:
		inv.inventory_changed.connect(update_slots)
	else:
		print("[player_inv] ⚠ No Inv resource assigned!")

	for s in slots:
		if s is InvUISlot:
			s.item_dropped_from_slot.connect(_on_item_dropped_from_slot)

	# create a dedicated CanvasLayer for drag ghosts and ensure it is on top
	drag_layer = CanvasLayer.new()
	# use a high layer so it renders above everything
	drag_layer.layer = 100
	# add to scene root deferred (safe during _ready)
	get_tree().root.call_deferred("add_child", drag_layer)

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

	# update ghost position if dragging
	if dragging and ghost_item and is_instance_valid(ghost_item):
		if ghost_item.has_method("get_rect"):
			ghost_item.global_position = get_viewport().get_mouse_position() - ghost_item.get_rect().size * 0.5
		else:
			ghost_item.global_position = get_viewport().get_mouse_position()

# --- Inventory toggle ---
func open():
	visible = true
	is_open = true
	update_slots()
	for slot in slots:
		if slot and slot.has_method("update_visual"):
			slot.update_visual()

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

	# Already dragging? ignore extra clicks
	if ghost_item:
		print("[player_inv][_on_item_clicked] ❌ already dragging a ghost:", ghost_item)
		return

	# Report click
	print("[player_inv][_on_item_clicked] clicked ItemStackUI:", item_stack, " parent:", item_stack.get_parent())

	# Resolve origin slot reference
	picked_slot = item_stack.slot
	print("[player_inv][_on_item_clicked] picked_slot:", picked_slot)

	if picked_slot == null:
		print("[player_inv][_on_item_clicked] ⚠ picked_slot is null — aborting")
		return

	# Print slot contents before clearing
	print("[player_inv][_on_item_clicked] origin slot BEFORE clear -> item:", picked_slot.item, " amount:", picked_slot.amount)

	# === Create ghost ===
	# Reuse the visual node if possible (keeps same scene)
	ghost_item = item_stack.duplicate() if item_stack else isgc.instantiate()
	# Ensure the ghost has no live slot reference (it's a visual only)
	ghost_item.slot = null

	# Preserve concrete origin data on ghost so update() shows texture/amount
	ghost_item.origin_item = picked_slot.item
	ghost_item.origin_amount = picked_slot.amount
	ghost_item.origin_slot = picked_slot

	# Force ghost to show the correct visual immediately
	ghost_item.call_deferred("update")
	ghost_item.visible = true

	# Defensive: ensure the ItemDisplay texture is set even if update delayed
	if ghost_item.item_visual and ghost_item.origin_item:
		ghost_item.item_visual.texture = ghost_item.origin_item.icon
		ghost_item.item_visual.visible = true

	# Make the ghost ignore mouse so it doesn't block events below
	ghost_item.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Give a reasonable size so it isn't tiny due to layout changes.
	# Try to size to the icon texture if available, fallback to 48x48.
	var tex_size = Vector2(48,48)
	if ghost_item.item_visual and ghost_item.item_visual.texture:
		tex_size = ghost_item.item_visual.texture.get_size()
	# clamp or scale down if extremely large
	var max_size = Vector2(96,96)
	if tex_size.x > max_size.x or tex_size.y > max_size.y:
		tex_size = tex_size.clamped(max_size)
	# Apply rect_size if available (Control)
	if "rect_size" in ghost_item:
		ghost_item.rect_size = tex_size
	# reset scale
	ghost_item.scale = Vector2.ONE

	# Immediately clear the origin slot so UI shows empty while dragging
	picked_slot.item = null
	picked_slot.amount = 0
	print("[player_inv][_on_item_clicked] origin slot cleared -> now item:", picked_slot.item, " amount:", picked_slot.amount)

	# Refresh visuals so the original slot immediately appears empty
	update_slots()
	for slot in slots:
		if slot and slot.has_method("update_visual"):
			slot.update_visual()
	print("[player_inv][_on_item_clicked] update_slots() called")

	# Add ghost to our drag_layer (ensures it renders above UI/world)
	if drag_layer and is_instance_valid(drag_layer):
		# ensure ghost is not already parented
		if is_instance_valid(ghost_item.get_parent()):
			ghost_item.get_parent().remove_child(ghost_item)
		drag_layer.add_child(ghost_item)
	else:
		# fallback to root if something weird happens
		if is_instance_valid(ghost_item.get_parent()):
			ghost_item.get_parent().remove_child(ghost_item)
		get_tree().root.call_deferred("add_child", ghost_item)

	# position and z
	if ghost_item is Control:
		ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)
		ghost_item.z_index = 9999
		_update_ghost_position()

	# Force update/redraw to avoid delayed invisibility
	ghost_item.call_deferred("update")
	ghost_item.queue_redraw()

	print("[player_inv][_on_item_clicked] ghost created:", ghost_item, "at", ghost_item.global_position)
	dragging = true

func _update_ghost_position():
	if not ghost_item or not is_instance_valid(ghost_item):
		return
	var mouse_pos = get_viewport().get_mouse_position()
	var offset = Vector2.ZERO
	# prefer using rect_size if available
	if "rect_size" in ghost_item and ghost_item.rect_size != Vector2.ZERO:
		offset = ghost_item.rect_size * 0.5
	elif ghost_item is Control and ghost_item.size != Vector2.ZERO:
		offset = ghost_item.size * 0.5
	elif ghost_item.item_visual and ghost_item.item_visual.texture:
		offset = ghost_item.item_visual.texture.get_size() * 0.5
	else:
		offset = Vector2(24,24)
	ghost_item.global_position = mouse_pos - offset
# --- Drop handling ---
func _unhandled_input(event: InputEvent) -> void:
	if ghost_item == null or picked_slot == null:
		return

	if event is InputEventMouseButton and not event.pressed:
		var mouse_pos = get_viewport().get_mouse_position()
		var dropped := false
		var moving_item := ghost_item.origin_item
		var moving_amount := ghost_item.origin_amount
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
					var player_node: Node = get_tree().get_root().find_child("Player", true, false)
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
					var player_node2: Node = get_tree().get_root().find_child("Player", true, false)
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
						if moving_item == null:
							print("[player_inv] ⚠ Tried to move null item")
						elif "name" in moving_item:
							print("[player_inv] ✅ Moved", moving_item.name, "to inventory")
						else:
							print("[player_inv] ✅ Moved unnamed item to inventory:", moving_item)
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
						player.equip_armor("")

		# --- Cleanup ---
		dragging = false
		if ghost_item and is_instance_valid(ghost_item):
			ghost_item.queue_free()
			ghost_item = null
		picked_slot = null

		update_slots()
		for slot in slots:
			if slot and slot.has_method("update_visual"):
				slot.update_visual()
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
