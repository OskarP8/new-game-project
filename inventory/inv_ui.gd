extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $NinePatchRect/GridContainer.get_children()

var is_open := false
var drag_layer: CanvasLayer

var ghost_item: ItemStackUI = null
var picked_slot: InvSlot = null

func _ready():
	drag_layer = CanvasLayer.new()
	get_tree().root.call_deferred("add_child", drag_layer)

	# assign index to each slot
	for i in range(slots.size()):
		slots[i].index = i

	if inv:
		inv.inventory_changed.connect(update_slots)
	update_slots()
	close()

func _process(_delta):
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()

	_update_item_in_hand()

# -------------------
# SLOT HANDLING
# -------------------
func update_slots() -> void:
	if inv == null:
		return

	# ensure inventory array is at least as big as UI slots
	if inv.slots.size() < slots.size():
		for i in range(slots.size() - inv.slots.size()):
			inv.slots.append(InvSlot.new())

	for i in range(slots.size()):
		if i >= inv.slots.size():
			break

		var inv_slot: InvSlot = inv.slots[i]

		# ensure slot object always exists
		if inv_slot == null:
			inv_slot = InvSlot.new()
			inv.slots[i] = inv_slot

		# clear visuals for empty inventory slots
		if inv_slot.item == null:
			if slots[i].item_stack and is_instance_valid(slots[i].item_stack):
				slots[i].item_stack.queue_free()
			slots[i].item_stack = null
			continue

		# create visual if missing
		var item_stack: ItemStackUI = slots[i].item_stack
		if item_stack == null or not is_instance_valid(item_stack):
			item_stack = isgc.instantiate()
			slots[i].insert(item_stack)
			# connect once
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

# -------------------
# DRAG & DROP
# -------------------
func _on_item_clicked(item_stack: ItemStackUI) -> void:
	if item_stack == null or not is_instance_valid(item_stack):
		return
	if ghost_item: # already dragging something
		return

	# origin slot object (may be cleared immediately)
	picked_slot = item_stack.slot

	# save concrete item data from origin
	var moving_item: InvItem = null
	var moving_amount: int = 0
	if picked_slot:
		moving_item = picked_slot.item
		moving_amount = picked_slot.amount

	# instantiate ghost and stash concrete data on it
	ghost_item = isgc.instantiate()
	ghost_item.slot = null
	ghost_item.origin_item = moving_item
	ghost_item.origin_amount = moving_amount
	ghost_item.origin_slot = picked_slot

	# Immediately clear origin slot so UI shows empty while dragging
	if picked_slot:
		picked_slot.item = null
		picked_slot.amount = 0

	# refresh visuals so origin looks empty right away
	update_slots()

	# add ghost to drag layer then update it (deferred to ensure onready nodes exist)
	drag_layer.add_child(ghost_item)
	ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ghost_item.call_deferred("update")
	ghost_item.visible = true

	# hide the real UI item if it's still around (safe)
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
			print("[inv_ui] dropped into player inventory → transferring")
			if player_inv.inv:
				var entry := InventoryEntry.new()
				entry.item = moving_item
				entry.quantity = moving_amount
				player_inv.inv.add_item(entry)
			dropped = true

		# 3️⃣ Drop outside → restore original
		if not dropped and picked_slot:
			picked_slot.item = moving_item
			picked_slot.amount = moving_amount

		# Cleanup ghost
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
