extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $".".get_children()

var is_open := false
var ghost_item: ItemStackUI = null
var picked_slot: InvSlot = null
var drag_layer: CanvasLayer = null

func _ready():
	# ✅ Ensure inventory exists
	if inv == null:
		inv = Inv.new()
		print("[player_inv] created internal Inv")

	# ✅ Ensure inv.slots array exists and matches UI size
	if inv.slots == null:
		inv.slots = []
	if inv.slots.size() < slots.size():
		for i in range(slots.size() - inv.slots.size()):
			inv.slots.append(InvSlot.new())
		print("[player_inv] filled inv.slots to size", inv.slots.size())

	# ✅ Assign indices to each UI slot (for reference)
	for i in range(slots.size()):
		if not slots[i].has_meta("index"):
			slots[i].set_meta("index", i)

	# create drag layer for ghost visuals
	drag_layer = CanvasLayer.new()
	get_tree().root.call_deferred("add_child", drag_layer)

	close()
	update_slots()
	print("[player_inv] ready: slots_count =", slots.size(), "inv_slots_count =", inv.slots.size())

func _process(_delta):
	if Input.is_action_just_pressed("i"):
		if is_open:
			close()
		else:
			open()
	_update_item_in_hand()

func open():
	visible = true
	is_open = true
	print("[player_inv] open()")
	update_slots()

func close():
	visible = false
	is_open = false
	print("[player_inv] close()")

# ---------------------------
# ITEM CLICK / DRAG START
# ---------------------------
func _on_item_clicked(item_stack: ItemStackUI) -> void:
	print("[player_inv] _on_item_clicked called. item_stack:", item_stack)
	if ghost_item:
		print("[player_inv]  -> already dragging ghost_item, ignoring click")
		return

	if item_stack == null or not is_instance_valid(item_stack):
		print("[player_inv]  -> item_stack null or invalid")
		return

	picked_slot = item_stack.slot
	if picked_slot == null:
		print("[player_inv]    WARNING: picked_slot is null for this item_stack.")
		return

	if not picked_slot.item:
		print("[player_inv]  -> no item in picked_slot to pick up")
		return

	print("[player_inv]  -> picking item id:", picked_slot.item.id, "amount:", picked_slot.amount)

	ghost_item = isgc.instantiate()
	ghost_item.slot = null
	ghost_item.origin_item = picked_slot.item
	ghost_item.origin_amount = picked_slot.amount
	ghost_item.origin_slot = picked_slot

	picked_slot.item = null
	picked_slot.amount = 0

	drag_layer.add_child(ghost_item)
	ghost_item.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ghost_item.call_deferred("update")
	ghost_item.visible = true

	item_stack.visible = false
	print("[player_inv]  -> ghost created, following mouse.")

	_update_item_in_hand()

# ---------------------------
# ITEM DROP
# ---------------------------
func _unhandled_input(event: InputEvent) -> void:
	if not ghost_item:
		return

	if event is InputEventMouseButton and not event.pressed:
		print("[player_inv] _unhandled_input: mouse release detected")
		var mouse_pos = get_viewport().get_mouse_position()
		var dropped = false

		var moving_item: InvItem = ghost_item.origin_item
		var moving_amount: int = ghost_item.origin_amount

		for idx in range(slots.size()):
			var slot_node = slots[idx]
			if not slot_node or not slot_node.has_method("get_global_rect"):
				continue
			if not slot_node.get_global_rect().has_point(mouse_pos):
				continue

			print("[player_inv]  -> drop target:", slot_node.name, "index:", idx)

			# ✅ Ensure target InvSlot exists
			if idx >= inv.slots.size():
				for i in range(idx - inv.slots.size() + 1):
					inv.slots.append(InvSlot.new())
			if inv.slots[idx] == null:
				inv.slots[idx] = InvSlot.new()

			var target_slot: InvSlot = inv.slots[idx]

			# Handle same-slot drop
			if target_slot == picked_slot:
				print("[player_inv] same slot -> return item")
				target_slot.item = moving_item
				target_slot.amount = moving_amount
				dropped = true
				break

			# Weapon Slot rule
			if slot_node.name == "WeaponSlot":
				if moving_item.type == "weapon":
					target_slot.item = moving_item
					target_slot.amount = moving_amount
					print("[player_inv] equipped weapon")
					dropped = true
				else:
					print("[player_inv] cannot equip non-weapon to WeaponSlot")
				break

			# Armor Slot rule
			if slot_node.name == "ArmorSlot":
				if moving_item.type == "armor":
					target_slot.item = moving_item
					target_slot.amount = moving_amount
					print("[player_inv] equipped armor")
					dropped = true
				else:
					print("[player_inv] cannot equip non-armor to ArmorSlot")
				break

			# Empty slot
			if target_slot.item == null:
				target_slot.item = moving_item
				target_slot.amount = moving_amount
				print("[player_inv] moved item into empty slot")
				dropped = true
				break

			# Swap items
			print("[player_inv] swapping items")
			var temp_item = target_slot.item
			var temp_amount = target_slot.amount
			target_slot.item = moving_item
			target_slot.amount = moving_amount

			if picked_slot:
				picked_slot.item = temp_item
				picked_slot.amount = temp_amount
			dropped = true
			break

		if not dropped:
			print("[player_inv] dropped outside -> restoring origin")
			if picked_slot:
				picked_slot.item = ghost_item.origin_item
				picked_slot.amount = ghost_item.origin_amount

		if ghost_item:
			ghost_item.queue_free()
			ghost_item = null
		picked_slot = null
		update_slots()

# ---------------------------
# UI HELPERS
# ---------------------------
func update_slots():
	print("[player_inv] update_slots: inv.slots.size =", (inv.slots.size() if inv else "nil"), "ui slots.size =", slots.size())
	if inv == null or slots.size() == 0:
		return

	for i in range(slots.size()):
		if i >= inv.slots.size():
			inv.slots.append(InvSlot.new())

		var inv_slot: InvSlot = inv.slots[i]

		if inv_slot.item == null:
			if slots[i].item_stack and is_instance_valid(slots[i].item_stack):
				slots[i].item_stack.queue_free()
			slots[i].item_stack = null
			continue

		var item_stack: ItemStackUI = slots[i].item_stack
		if item_stack == null or not is_instance_valid(item_stack):
			item_stack = isgc.instantiate()
			slots[i].insert(item_stack)
			item_stack.clicked.connect(Callable(self, "_on_item_clicked"))

		item_stack.slot = inv_slot
		item_stack.call_deferred("update")

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
