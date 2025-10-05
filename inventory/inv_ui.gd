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

		# data being moved comes from ghost (we cleared origin already)
		var moving_item: InvItem = ghost_item.origin_item
		var moving_amount: int = ghost_item.origin_amount

		for slot in slots:
			if slot.get_global_rect().has_point(mouse_pos):
				# ensure inv.slots has that index
				if slot.index >= inv.slots.size():
					var needed = slot.index + 1 - inv.slots.size()
					for i in range(needed):
						inv.slots.append(InvSlot.new())

				var target_slot: InvSlot = inv.slots[slot.index]
				if target_slot == null:
					target_slot = InvSlot.new()
					inv.slots[slot.index] = target_slot

				# If nothing to move, bail
				if moving_item == null:
					dropped = true
					break

				# SAME SLOT: if target is the same InvSlot object as origin -> return item
				if picked_slot != null and target_slot == picked_slot:
					target_slot.item = moving_item
					target_slot.amount = moving_amount
					dropped = true
					break

				# STACK: same id & stackable
				if target_slot.item and target_slot.item.id == moving_item.id and not _is_non_stackable(moving_item):
					target_slot.amount += moving_amount
					# origin already cleared
				# SWAP: target occupied and not stackable with moving item (or different)
				elif target_slot.item:
					var temp_item = target_slot.item
					var temp_amount = target_slot.amount

					# place moving into target
					target_slot.item = moving_item
					target_slot.amount = moving_amount

					# put replaced item into origin (picked_slot) if available, otherwise find first empty
					if picked_slot != null:
						picked_slot.item = temp_item
						picked_slot.amount = temp_amount
					else:
						# fallback: place into the first empty inv slot (ensure exists)
						var placed = false
						for i in range(inv.slots.size()):
							if inv.slots[i] == null:
								inv.slots[i] = InvSlot.new()
							if inv.slots[i].item == null:
								inv.slots[i].item = temp_item
								inv.slots[i].amount = temp_amount
								placed = true
								break
						if not placed:
							var new_slot = InvSlot.new()
							new_slot.item = temp_item
							new_slot.amount = temp_amount
							inv.slots.append(new_slot)
				# MOVE into empty target
				else:
					target_slot.item = moving_item
					target_slot.amount = moving_amount

				dropped = true
				break

		# Dropped outside → clear picked slot safely if outside inventory border
		if not dropped and picked_slot:
			if not get_global_rect().has_point(mouse_pos):
				# Clear the picked slot if dropped outside inventory
				picked_slot.item = null
				picked_slot.amount = 0
			else:
				# Restore the original item and amount
				picked_slot.item = ghost_item.origin_item
				picked_slot.amount = ghost_item.origin_amount

		# Cleanup ghost
		if ghost_item:
			ghost_item.queue_free()
			ghost_item = null

		# Reset picked_slot
		picked_slot = null

		# Refresh the UI
		update_slots()

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
