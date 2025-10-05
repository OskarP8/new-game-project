extends Control

@export var inv: Inv
@onready var isgc = preload("res://scenes/item_stack_ui.tscn")
@onready var slots: Array = $".".get_children()

var is_open := false
var ghost_item: Control = null
var picked_slot: InvSlot = null

func _ready():
	if inv:
		inv.inventory_changed.connect(update_slots)
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
	for i in range(slots.size()):
		if i >= inv.slots.size():
			break

		var inv_slot: InvSlot = inv.slots[i]
		if inv_slot == null:
			inv_slot = InvSlot.new()
			inv.slots[i] = inv_slot

		# Remove old visual if invalid
		if slots[i].item_stack and not is_instance_valid(slots[i].item_stack):
			slots[i].item_stack = null

		# Skip empty
		if inv_slot.item == null:
			if slots[i].item_stack:
				slots[i].container.remove_child(slots[i].item_stack)
				slots[i].item_stack = null
			continue

		# Create or reuse item_stack_ui
		var item_stack: ItemStackUI = slots[i].item_stack
		if item_stack == null:
			item_stack = isgc.instantiate()
			slots[i].insert(item_stack)
			item_stack.connect("clicked", Callable(self, "_on_item_clicked").bind(item_stack))
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

		# Declare inv_ui up front so it's visible everywhere
		var inv_ui := get_tree().root.find_child("Inv_UI", true, false)

		# Clear picked slot temporarily
		picked_slot.item = null
		picked_slot.amount = 0

		# --- 1️⃣ Check if dropped on player inventory slots ---
		for idx in range(slots.size()):
			var slot_node = slots[idx]
			if slot_node.get_global_rect().has_point(mouse_pos):
				var target_slot: InvSlot = inv.slots[idx]

				if target_slot == picked_slot:
					print("[player_inv] same slot, snapping back")
					target_slot.item = moving_item
					target_slot.amount = moving_amount
					dropped = true
					break

				if target_slot.item == null:
					target_slot.item = moving_item
					target_slot.amount = moving_amount
					print("[player_inv] moved into empty slot")
					dropped = true
					break

				# Swap
				print("[player_inv] swapping items")
				var tmp_item = target_slot.item
				var tmp_amt = target_slot.amount
				target_slot.item = moving_item
				target_slot.amount = moving_amount
				picked_slot.item = tmp_item
				picked_slot.amount = tmp_amt
				dropped = true
				break

		# --- 2️⃣ Check if dropped inside main inventory (cross-transfer) ---
		if not dropped and inv_ui and inv_ui.visible and inv_ui.get_global_rect().has_point(mouse_pos):
			print("[player_inv] dropped inside main inventory -> transfer there")
			if inv_ui.inv:
				var entry := InventoryEntry.new()
				entry.item = moving_item
				entry.quantity = moving_amount
				inv_ui.inv.add_item(entry)
			dropped = true

		# --- 3️⃣ Dropped completely outside both inventories ---
		if not dropped:
			print("[player_inv] dropped outside all inventories -> discard")
			# Optionally: spawn it in the world here

		# --- Cleanup ---
		if ghost_item and is_instance_valid(ghost_item):
			ghost_item.queue_free()
			ghost_item = null
		picked_slot = null

		update_slots()
		if inv_ui:
			inv_ui.update_slots()
