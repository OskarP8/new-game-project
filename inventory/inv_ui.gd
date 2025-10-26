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

	# Add ghost to drag layer
	drag_layer.add_child(ghost_item)
	ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ghost_item.call_deferred("update")
	ghost_item.visible = true

	# Hide the real UI item if still around
	if is_instance_valid(item_stack):
		item_stack.visible = false

	_update_item_in_hand()


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

		# 3️⃣ Drop outside → restore original
		if not dropped and picked_slot:
			picked_slot.item = moving_item
			picked_slot.amount = moving_amount

		# Cleanup
		if ghost_item:
			ghost_item.queue_free()
		ghost_item = null
		picked_slot = null

		update_slots()
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
		if slot and "slot_type" in slot and str(slot.slot_type).to_lower() == str(slot_type).to_lower():
			return slot
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
